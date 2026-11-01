/* Definizioni che la libreria C di Android (bionic) non ha: solo per gli strumenti di compilazione del kernel */
#include <elf.h>
/* bionic le definisce passando per ELF_ST_BIND, che modpost.h ridefinisce: un giro che non si chiude */
#undef ELF64_ST_BIND
#undef ELF64_ST_TYPE
#undef ELF32_ST_BIND
#undef ELF32_ST_TYPE
#define ELF64_ST_BIND(i) ((i) >> 4)
#define ELF64_ST_TYPE(i) ((i) & 0xf)
#define ELF32_ST_BIND(i) ((i) >> 4)
#define ELF32_ST_TYPE(i) ((i) & 0xf)
#ifndef R_ARM_CALL
#define R_ARM_CALL 28
#define R_ARM_JUMP24 29
#define R_ARM_THM_JUMP24 30
#define R_ARM_MOVW_ABS_NC 43
#define R_ARM_MOVT_ABS 44
#define R_ARM_THM_MOVW_ABS_NC 47
#define R_ARM_THM_MOVT_ABS 48
#define R_ARM_THM_JUMP19 51
#endif
