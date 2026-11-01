/* operatori new/delete del C++ sopra malloc: il server di Termux:X11 usa solo <new>, e la libreria finale
 * non deve dipendere dalla libreria C++ di Termux (sul telefono la carica l'app, non Termux) */
#include <stdlib.h>
void *_Znwm(unsigned long n) { void *p = malloc(n ? n : 1); if (!p) abort(); return p; }            /* new */
void *_Znam(unsigned long n) { return _Znwm(n); }                                                  /* new[] */
void _ZdlPv(void *p) { free(p); }                                                                   /* delete */
void _ZdaPv(void *p) { free(p); }                                                                   /* delete[] */
void _ZdlPvm(void *p, unsigned long n) { (void)n; free(p); }                                        /* delete con misura */
void _ZdaPvm(void *p, unsigned long n) { (void)n; free(p); }
void __cxa_pure_virtual(void) { abort(); }
