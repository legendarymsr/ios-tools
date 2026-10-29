#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static uint32_t be32(const unsigned char *p){ return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
int main(int argc, char **argv) {
  FILE *f = argc>1 ? fopen(argv[1],"rb") : stdin;
  if (!f) { perror("open"); return 1; }
  unsigned char lead[96]; if (fread(lead,1,96,f)!=96 || memcmp(lead,"\xed\xab\xee\xdb",4)) { fprintf(stderr,"not rpm\n"); return 1; }
  unsigned char mh[16]; if (fread(mh,1,16,f)!=16) return 1;
  uint32_t nindex=be32(mh+8), hsize=be32(mh+12);
  fseek(f, (long)nindex*16 + (long)hsize, SEEK_CUR);
  long pos=ftell(f); if (pos%8) fseek(f, 8-(pos%8), SEEK_CUR);
  if (fread(mh,1,16,f)!=16) return 1;
  nindex=be32(mh+8); hsize=be32(mh+12);
  fseek(f, (long)nindex*16 + (long)hsize, SEEK_CUR);
  unsigned char magic[6]; long payload=ftell(f);
  if (fread(magic,1,6,f)!=6) return 1;
  fseek(f, payload, SEEK_SET);
  char tmp[]="/tmp/rpmXXXXXX"; int fd=mkstemp(tmp); if(fd<0){perror("mkstemp");return 1;}
  char buf[1<<16]; size_t r; while((r=fread(buf,1,sizeof buf,f))>0) write(fd,buf,r); close(fd);
  const char *cmd=0;
  if (magic[0]==0x1f && magic[1]==0x8b) cmd="gzip -dc";
  else if (magic[0]==0xfd && magic[1]=='7' && magic[2]=='z') cmd="xz -dc";
  else if (magic[0]==0x28 && magic[1]==0xb5) cmd="zstd -dc";
  else { fprintf(stderr,"unknown payload compression\n"); unlink(tmp); return 1; }
  char full[256]; snprintf(full,sizeof full, "%s <%s", cmd, tmp);
  FILE *p=popen(full,"r"); if(!p){perror("popen");unlink(tmp);return 1;}
  while((r=fread(buf,1,sizeof buf,p))>0) fwrite(buf,1,r,stdout);
  pclose(p); unlink(tmp); return 0;
}
