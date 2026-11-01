/* bionic definisce st_atime_nsec & c. come macro (sys/stat.h): rompono i campi omonimi di struct lkl_stat */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <sys/stat.h>
#undef st_atime_nsec
#undef st_mtime_nsec
#undef st_ctime_nsec
