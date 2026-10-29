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
  unsigned char mh[16];
  if (fread(mh,1,16,f)!=16) return 1;
  fseek(f, (long)be32(mh+8)*16 + (long)be32(mh+12), SEEK_CUR);
  long pos=ftell(f); if (pos%8) fseek(f, 8-(pos%8), SEEK_CUR);
  if (fread(mh,1,16,f)!=16) return 1;
  fseek(f, (long)be32(mh+8)*16 + (long)be32(mh+12), SEEK_CUR);
  char tmp[]="/tmp/rpmXXXXXX"; int fd=mkstemp(tmp); if(fd<0){perror("mkstemp");return 1;}
  char buf[1<<16]; size_t r; while((r=fread(buf,1,sizeof buf,f))>0) write(fd,buf,r); close(fd);
  /* try zstd, gzip, xz */
  const char *cmds[] = {"zstd -dc", "gzip -dc", "xz -dc", NULL};
  for (int i=0; cmds[i]; i++) {
    char full[512]; snprintf(full,sizeof full, "%s < '%s'", cmds[i], tmp);
    FILE *p=popen(full,"r"); if(!p) continue;
    size_t total=0;
    while((r=fread(buf,1,sizeof buf,p))>0) { fwrite(buf,1,r,stdout); total+=r; }
    int rc=pclose(p);
    if (rc==0 && total>0) { unlink(tmp); return 0; }
  }
  fprintf(stderr,"decompress failed\n"); unlink(tmp); return 1;
}
