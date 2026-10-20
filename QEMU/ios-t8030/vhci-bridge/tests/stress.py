import socket, struct, os, time, threading, sys, array, random, select
SEED=int(sys.argv[1]) if len(sys.argv)>1 else 1
random.seed(SEED)
P='/tmp/vt'; ATT=P+'/att.sock'; USB=P+'/usb.sock'
for f in (ATT,USB):
    try: os.unlink(f)
    except: pass
att=socket.socket(socket.AF_UNIX); att.bind(ATT); att.listen(1)
dev_rx=bytearray(); zlps=[0]          # OUT stream as seen by iOS
dev_tx=bytes((i*7+3)&0xff for i in range(400000)); dev_tx_pos=[0]   # IN stream iOS produces
max_req=[0]
def hcd():
    while not os.path.exists(USB): time.sleep(0.02)
    s=socket.socket(socket.AF_UNIX); s.connect(USB)
    rnd=random.Random(SEED*7)
    def rd(n):
        b=b''
        while len(b)<n:
            c=s.recv(n-len(b))
            if not c: raise SystemExit
            b+=c
        return b
    while True:
        try: t=rd(1)[0]
        except SystemExit: return
        if t==3: continue
        if t==4: rd(14); continue
        addr,pid,ep,id_,stream,sno,ir,ln=struct.unpack('<BiBQIBBH',rd(22))
        max_req[0]=max(max_req[0],ln)
        data=rd(ln) if (ln and pid!=0x69) else b''
        st=0; out=b''; L=0
        if rnd.random()<0.4: st=-2          # random NAK: nothing consumed/produced
        elif pid==0xe1:                     # OUT: iOS consumes it all
            dev_rx.extend(data); L=len(data)
            if ln==0: zlps[0]+=1
        elif pid==0x69:                     # IN: short or full packet
            n=min(ln, rnd.choice([ln, ln, 512, 100, 0, 3000]))
            out=dev_tx[dev_tx_pos[0]:dev_tx_pos[0]+n]; dev_tx_pos[0]+=len(out); L=len(out)
        s.sendall(bytes([2])+struct.pack('<BiBQIH',addr,pid,ep,id_,st&0xffffffff,L)+out)
threading.Thread(target=hcd,daemon=True).start()
c,_=att.accept()
msg,anc,_,_=c.recvmsg(1,socket.CMSG_LEN(4))
fd=array.array('i'); fd.frombytes(anc[0][2][:4]); v=socket.socket(fileno=fd[0])

host_tx=bytes((i*13+1)&0xff for i in range(600000)); OUT_TOTAL=300000
out_pos=0           # next byte to submit
host_rx=bytearray()
seq=[0]; inflight={}  # seq -> (kind, start, len)
pending_unlink={}     # unlink seq -> victim
resubmit=[]
result={}  # out seq -> delivered bytes reported to host
order=[]
def submit(kind,start,ln,flags=0):
    seq[0]+=1; s=seq[0]
    d=1 if kind=='in' else 0; ep=1 if kind=='in' else 2
    hdr=struct.pack('>IIIII',1,s,0x10001,d,ep)+struct.pack('>IiiiI',flags,ln,0,0,0)+b'\0'*8
    v.sendall(hdr+(host_tx[start:start+ln] if kind=='out' else b''))
    inflight[s]=(kind,start,ln)
    if kind=='out': order.append(s)
    return s
sizes=[1,511,512,1024,3000,16384,65536,20000,512*9]
in_target=150000
t0=time.time(); unlinks=0; acked=0
buf=b''
def outs(): return sum(1 for k in inflight.values() if k[0]=='out')
def ins(): return sum(1 for k in inflight.values() if k[0]=='in')
while time.time()-t0<40:
    # keep 4 OUT + 3 IN in flight (usbmuxd-like)
    while outs()<4 and out_pos<OUT_TOTAL:
        ln=min(random.choice(sizes), OUT_TOTAL-out_pos)
        flags=0x40 if ln%512==0 else 0
        s=submit('out',out_pos,ln,flags); out_pos+=ln
        if random.random()<0.08:
            seq[0]+=1; u=seq[0]; pending_unlink[u]=s; unlinks+=1
            v.sendall(struct.pack('>IIIII',2,u,0x10001,0,2)+struct.pack('>I',s)+b'\0'*24)
    while ins()<3 and len(host_rx)<in_target:
        submit('in',0,16384)
    if out_pos>=OUT_TOTAL and not inflight and len(host_rx)>=in_target: break
    r,_,_=select.select([v],[],[],0.5)
    if not r: continue
    chunk=v.recv(65536)
    if not chunk: break
    buf+=chunk
    while len(buf)>=48:
        cmd,s,_,_,_=struct.unpack('>IIIII',buf[:20])
        if cmd==3:
            st,actual=struct.unpack('>ii',buf[20:28])
            kind=inflight.get(s,('?',0,0))
            need=48+(actual if kind[0]=='in' else 0)
            if len(buf)<need: break
            body=buf[48:need]; buf=buf[need:]
            if s not in inflight: print('RET_SUBMIT for unknown seq',s); continue
            k,start,ln=inflight.pop(s)
            if k=='in': host_rx.extend(body)
            else:
                assert st in (0,-104), f'OUT status {st}'
                result[s]=host_tx[start:start+actual]
        elif cmd==4:
            (st,)=struct.unpack('>i',buf[20:24]); buf=buf[48:]
            victim=pending_unlink.pop(s,None)
            if victim in inflight:      # given back by unlink, nothing delivered
                k,start,ln=inflight.pop(victim); assert st==-104, st
                result[victim]=b''
        else: print('bad cmd',cmd); sys.exit(2)
    # re-send undelivered parts in order (this is where real usbmuxd would just
    # report an error; we only need to account for bytes)
    while resubmit and outs()<4:
        a,l=resubmit.pop(0); submit('out',a,l)
# Verdict
ok=True
# OUT: iOS must receive the host stream in order, gaps re-sent later appear later:
# so verify no duplicates and every delivered region is in submission order
exp=b''.join(result.get(s,b'<missing>') for s in order)
assert not inflight, f'{len(inflight)} URBs never completed'
if bytes(dev_rx)!=exp:
    ok=False
    i=next((i for i,(a,b) in enumerate(zip(dev_rx,exp)) if a!=b), min(len(dev_rx),len(exp)))
    print(f'OUT MISMATCH vs reported actuals at byte {i}: iOS got {len(dev_rx)} bytes, expected {len(exp)}')
if bytes(host_rx)!=dev_tx[:len(host_rx)]:
    ok=False; print('IN MISMATCH (reordered/lost IN data)')
print(f'seed={SEED} OUT {len(dev_rx)}/{OUT_TOTAL} bytes, IN {len(host_rx)} bytes, unlinks={unlinks}, ZLPs={zlps[0]}, max req len={max_req[0]}, {"PASS" if ok else "FAIL"}')
sys.exit(0 if ok else 1)
