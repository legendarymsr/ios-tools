// SPDX-License-Identifier: GPL-3.0-or-later
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
static int attach_fd=-1;
int open(const char *p, int fl, ...){
  static int (*ro)(const char*,int,...); if(!ro) ro=dlsym(RTLD_NEXT,"open");
  va_list a; va_start(a,fl); int m=va_arg(a,int); va_end(a);
  if (strstr(p,"/attach")) { int s=socket(AF_UNIX,SOCK_STREAM,0); struct sockaddr_un u={.sun_family=AF_UNIX};
    strcpy(u.sun_path,getenv("ATTACH_SOCK")); connect(s,(void*)&u,sizeof u); attach_fd=s; return s; }
  return ro(p,fl,m);
}
ssize_t write(int fd,const void*b,size_t n){
  static ssize_t (*rw)(int,const void*,size_t); if(!rw) rw=dlsym(RTLD_NEXT,"write");
  if (fd==attach_fd && attach_fd>=0) { char t[64]; snprintf(t,sizeof t,"%.*s",(int)n,(const char*)b);
    unsigned port; int sfd; sscanf(t,"%u %d",&port,&sfd);
    char c=0; struct iovec io={&c,1}; char cm[CMSG_SPACE(sizeof(int))]; struct msghdr mh={0};
    mh.msg_iov=&io; mh.msg_iovlen=1; mh.msg_control=cm; mh.msg_controllen=sizeof cm;
    struct cmsghdr *h=CMSG_FIRSTHDR(&mh); h->cmsg_level=SOL_SOCKET; h->cmsg_type=SCM_RIGHTS; h->cmsg_len=CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(h),&sfd,sizeof(int)); sendmsg(fd,&mh,0); return n; }
  return rw(fd,b,n);
}
