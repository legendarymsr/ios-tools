#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <mach/mach.h>
int main(void) {
  struct utsname u; uname(&u);
  char model[256]={0}, os[256]={0}, host[256]={0};
  size_t n=sizeof model; sysctlbyname("hw.machine",model,&n,0,0);
  n=sizeof os; sysctlbyname("kern.osproductversion",os,&n,0,0);
  gethostname(host,sizeof host);
  int ncpu=0; n=sizeof ncpu; sysctlbyname("hw.ncpu",&ncpu,&n,0,0);
  int64_t mem=0; n=sizeof mem; sysctlbyname("hw.memsize",&mem,&n,0,0);
  vm_statistics64_data_t vs; mach_msg_type_number_t cnt=HOST_VM_INFO64_COUNT;
  host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vs, &cnt);
  double used=(double)(vs.active_count+vs.wire_count)*getpagesize()/(1024*1024*1024.0);
  double total=mem/(1024.0*1024*1024);
  char *user=getenv("USER"); if(!user) user="root";
  printf("\n");
  printf("        %s@%s\n", user, host);
  printf("        ------------\n");
  printf("OS:     iOS %s (%s %s)\n", os[0]?os:u.release, u.sysname, u.machine);
  printf("Host:   %s\n", model);
  printf("Kernel: %s\n", u.release);
  printf("CPU:    %s (%d)\n", u.machine, ncpu);
  printf("Memory: %.1f GiB / %.1f GiB\n", used, total);
  printf("Shell:  HelloWorld terminal (TrollStore root)\n");
  printf("Pkgs:   dnf (ios-tools)\n");
  printf("\n");
  return 0;
}
