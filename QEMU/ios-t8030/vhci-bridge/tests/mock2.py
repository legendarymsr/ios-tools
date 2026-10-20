import socket, struct, os, time, threading, sys, array
P='/tmp/vt'; ATT=P+'/att.sock'; USB=P+'/usb.sock'
for f in (ATT,USB):
    try: os.unlink(f)
    except: pass
att=socket.socket(socket.AF_UNIX); att.bind(ATT); att.listen(1)
global_resets=[0]
DESC=bytes([18,1,0,2,0,0,0,64,0xac,0x05,0x81,0x12,0,1,1,2,3,1])
def hcd():
    # wait for bridge socket, then connect like iOS hcd-tcp
    while not os.path.exists(USB): time.sleep(0.05)
    s=socket.socket(socket.AF_UNIX); s.connect(USB)
    armed_at=None; stage=None; naks=0
    def rd(n):
        b=b''
        while len(b)<n:
            c=s.recv(n-len(b))
            if not c: raise SystemExit
            b+=c
        return b
    while True:
        t=rd(1)[0]
        if t==3:
            global_resets[0]+=1
            if global_resets[0]>=2: armed_at=time.time()+0.05
            print("[hcd] RESET rx #%d" % global_resets[0],flush=True); continue
        if t!=1: print('[hcd] type',t); continue
        addr,pid,ep,id_,stream,sno,ir,ln=struct.unpack('<BiBQIBBH',rd(22))
        data=rd(ln) if (ln and pid!=0x69) else b''
        armed = armed_at is not None and time.time()>=armed_at
        st=0; out=b''
        if not armed: st=-2; naks+=1
        elif pid==0x2d: stage='setup'
        elif pid==0x69 and stage=='setup': out=DESC[:ln]; stage='data'
        hdr=struct.pack('<BiBQIH',addr,pid,ep,id_,st & 0xffffffff,len(out))
        s.sendall(bytes([2])+hdr+out)
        if pid==0x69 and out: print(f'[hcd] served descriptor after {naks} NAKs',flush=True)
threading.Thread(target=hcd,daemon=True).start()
c,_=att.accept()
msg,anc,_,_=c.recvmsg(1,socket.CMSG_LEN(4))
fd=array.array('i'); fd.frombytes(anc[0][2][:4]); v=socket.socket(fileno=fd[0])
print('[vhci] got attach fd',flush=True)
# CMD_SUBMIT GET_DESCRIPTOR(device, 18) dir IN ep0, big endian
setup=bytes([0x80,6,0,1,0,0,18,0])
hdr=struct.pack('>IIIII',1,1,0x10001,1,0)+struct.pack('>IiiiI',0x200,18,0,0,0)+setup
v.sendall(hdr)
v.settimeout(8)
r=b''
while len(r)<48: r+=v.recv(48-len(r))
cmd,seq,_,_,_,status,actual=struct.unpack('>IIIIIii',r[:28])
body=b''
while len(body)<actual: body+=v.recv(actual-len(body))
print(f'[vhci] RET_SUBMIT cmd={cmd} seq={seq} status={status} actual={actual} vid={body[8:10][::-1].hex()} pid={body[10:12][::-1].hex()}')
sys.exit(0 if status==0 and actual==18 else 1)
