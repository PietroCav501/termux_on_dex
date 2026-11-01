// tod-diretto.so — per le app di Debian avviate senza proot (lib/diretto.sh, share/diretto/tod-diretto).
//
// Il programma parte con il caricatore di Debian corretto (correggi.py) e libfakechroot, che fa vedere
// all'app /usr, /etc... del container. Qui si sistema quello che fakechroot non vede:
//  - /proc/self/exe punta al caricatore: si risponde con il programma vero, e chi rilancia
//    /proc/self/exe (Chromium, Electron) rilancia il programma vero; lo stesso per /proc/<pid>/exe delle
//    altre app partite così (la "seconda copia" di Electron riconosce la prima);
//  - le chiamate che Android vieta alle app (seccomp, "trap"): invece di chiudere il programma
//    rispondono -ENOSYS, come un kernel che non le ha (io_uring...), e i programmi ripiegano da soli;
//    accept no: diventa accept4, che Android permette;
//  - libuv (Node, Electron) chiama statx da sé: il percorso si traduce qui;
//  - i file che il glibc apre al suo interno (/etc/resolv.conf, /etc/passwd...): nella copia della libc
//    sono diventati /dev/fd/NN, e qui si aprono quei descrittori sui file del container;
//  - apt, dpkg, sudo, pkexec vogliono essere root: si rilanciano in proot (share/diretto/tod-proot);
//  - gli script (#!): fakechroot con il caricatore ne perde gli ultimi due argomenti (pkexec apt-get
//    install -y <file.deb> arrivava senza il .deb: ArtCraft, 26 ottobre). La riga #! la leggiamo noi e
//    si lancia l'interprete, come fa il kernel (execve, execvp, posix_spawn, posix_spawnp);
//  - le azioni di posix_spawn (cartella di partenza, file da aprire) il glibc le fa senza fakechroot:
//    i loro percorsi si traducono qui.
//
// Senza intestazioni: si compila con il clang di Termux per glibc, collegato alla libc.so.6 del container
// (diretto_compila in lib/diretto.sh; nel container non c'è un compilatore).

typedef unsigned long size_t;
typedef long ssize_t;
#define RTLD_NEXT ((void *)-1l)
#define O_RDONLY 0
#define O_CLOEXEC 02000000
void *dlsym(void *, const char *);
int open(const char *, int, ...);
ssize_t read(int, void *, size_t);
int close(int);
int access(const char *, int);
int dup3(int, int, int);
size_t strlen(const char *);
int strcmp(const char *, const char *);
int strncmp(const char *, const char *, size_t);
char *strrchr(const char *, int);
void *memcpy(void *, const void *, size_t);
char *getenv(const char *);
int snprintf(char *, size_t, const char *, ...);
extern char **environ;
typedef int pid_t;

struct tod_sigaction { void (*azione)(int, void *, void *); unsigned long maschera[16]; int flag; void (*ripristino)(void); };
int sigaction(int, const struct tod_sigaction *, struct tod_sigaction *);
#define SIGSYS 31
#define SA_SIGINFO 4
#define SA_RESTART 0x10000000
#define UC_X0 184   // ucontext_t di aarch64: uc_mcontext (176) + fault_address
#define NR_STATX 291
#define NR_EXECVE 221
#define NR_ACCEPT 202
#define NR_ACCEPT4 242

// stessi numeri di correggi.py (FILE)
static const struct { int fd; const char *file; } FILE_GLIBC[] = {
  {97, "/etc/resolv.conf"}, {96, "/etc/hosts"}, {95, "/etc/passwd"}, {94, "/etc/group"},
  {93, "/etc/nsswitch.conf"}, {92, "/usr/lib/locale/locale-archive"}, {91, "/etc/services"},
  {90, "/etc/host.conf"}, {89, "/etc/gai.conf"}, {0, 0},
};

// i programmi che vogliono essere root: in proot (lì c'è root finto e sudo)
static const char *DA_ROOT[] = {"sudo", "pkexec", "su", "apt", "apt-get", "aptitude", "dpkg", "synaptic-pkexec", 0};

static const char *FUORI[] = {"/proc", "/dev", "/sys", "/data", "/storage", "/sdcard", "/apex", "/system", "/vendor", 0};

static char exe[4096];   // il programma, come lo vede l'app (/usr/...)
static const char *base;
static size_t lbase;

long syscall(long nr, long a, long b, long c, long d, long e, long f);
int accept4(int, void *, unsigned *, int);
int *__errno_location(void);

static void vietata(int sig, void *info, void *uc) {
  (void)sig; (void)info;
  long *x = (long *)((char *)uc + UC_X0);   // x0..x30 del programma; il numero della chiamata è in x8
  // accept: Android lascia alle app solo accept4 (la sua libc fa così). Con -ENOSYS Electron non accettava
  // mai il collegamento della "seconda copia": il link di ritorno da Chromium chiudeva l'app dopo 20 s (28 ottobre)
  if (x[8] == NR_ACCEPT) {
    long r = syscall(NR_ACCEPT4, x[0], x[1], x[2], 0, 0, 0);
    x[0] = r == -1 ? -*__errno_location() : r;   // come il kernel: -errore nel registro
    return;
  }
  x[0] = -38;
}

// la stessa cosa per chi passa dal glibc (accept del glibc chiama la syscall accept, vietata)
int accept(int fd, void *indirizzo, unsigned *lunghezza) {
  return accept4(fd, indirizzo, lunghezza, 0);
}

// il programma di un processo partito senza proot: dopo le opzioni del caricatore nella sua riga di comando
// (ld.so --argv0 X <programma> ...), come lo vede l'app (/usr/..., senza il percorso del container)
static int programma(const char *cmdline, char *out, size_t max) {
  char buf[65536];
  int fd = open(cmdline, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0;
  ssize_t n = read(fd, buf, sizeof buf - 1);
  close(fd);
  if (n <= 0) return 0;
  buf[n] = 0;
  char *p = buf, *fine = buf + n;
  p += strlen(p) + 1;
  while (p < fine && strncmp(p, "--", 2) == 0) {   // --preload X, --argv0 X, --library-path X
    p += strlen(p) + 1;
    if (p < fine) p += strlen(p) + 1;
  }
  if (p >= fine || *p != '/') return 0;
  if (lbase && strncmp(p, base, lbase) == 0) p += lbase;
  snprintf(out, max, "%s", p);
  return 1;
}

__attribute__((constructor)) static void avvio(void) {
  struct tod_sigaction sa = {0};
  sa.azione = vietata;
  sa.flag = SA_SIGINFO | SA_RESTART;
  sigaction(SIGSYS, &sa, 0);

  base = getenv("FAKECHROOT_BASE");
  lbase = base ? strlen(base) : 0;
  if (base) {
    char r[4096];
    for (int i = 0; FILE_GLIBC[i].file; i++) {
      snprintf(r, sizeof r, "%s%s", base, FILE_GLIBC[i].file);
      int f = open(r, O_RDONLY | O_CLOEXEC);
      if (f >= 0 && f != FILE_GLIBC[i].fd) { dup3(f, FILE_GLIBC[i].fd, O_CLOEXEC); close(f); }
    }
  }

  programma("/proc/self/cmdline", exe, sizeof exe);
}

static int e_self(const char *path) {
  return path && exe[0] && (!strcmp(path, "/proc/self/exe") || !strcmp(path, "/proc/thread-self/exe"));
}

static const char *traduci(const char *p, char *buf, size_t n) {
  if (!p || p[0] != '/' || !base) return p;
  if (!strncmp(p, base, lbase)) return p;
  for (int i = 0; FUORI[i]; i++) {
    size_t l = strlen(FUORI[i]);
    if (!strncmp(p, FUORI[i], l) && (p[l] == 0 || p[l] == '/')) return p;
  }
  snprintf(buf, n, "%s%s", base, p);
  return buf;
}

// /proc/<pid>/exe di un'altra app partita senza proot punta al caricatore: si risponde con il suo programma.
// Electron e Chromium controllano così che la copia già aperta sia "lo stesso programma": senza, ogni
// il link di ritorno da Chromium apriva una copia nuova dell'app invece di passare l'accesso a quella aperta (28 ottobre).
// Corregge il risultato già letto (r): readlink e readlinkat non si chiamano a vicenda (fakechroot passa
// dall'una all'altra: un giro senza fine)
static ssize_t altro_exe(const char *path, char *buf, size_t len, ssize_t r) {
  const char *ld = getenv("FAKECHROOT_ELFLOADER");
  if (r <= 0 || !ld || !path || strncmp(path, "/proc/", 6) || (size_t)r != strlen(ld) || strncmp(buf, ld, (size_t)r))
    return r;
  const char *q = path + 6;
  while (*q >= '0' && *q <= '9') q++;
  if (q == path + 6 || strcmp(q, "/exe")) return r;
  char cmd[64], prog[4096];
  snprintf(cmd, sizeof cmd, "%.*s/cmdline", (int)(q - path), path);
  if (!programma(cmd, prog, sizeof prog)) return r;
  size_t l = strlen(prog);
  if (l > len) l = len;
  memcpy(buf, prog, l);
  return (ssize_t)l;
}

ssize_t readlink(const char *path, char *buf, size_t len) {
  static ssize_t (*vero)(const char *, char *, size_t);
  if (!vero) vero = dlsym(RTLD_NEXT, "readlink");
  if (e_self(path)) {
    size_t l = strlen(exe);
    if (l > len) l = len;
    memcpy(buf, exe, l);
    return (ssize_t)l;
  }
  return altro_exe(path, buf, len, vero(path, buf, len));
}

ssize_t readlinkat(int dir, const char *path, char *buf, size_t len) {
  static ssize_t (*vero)(int, const char *, char *, size_t);
  if (!vero) vero = dlsym(RTLD_NEXT, "readlinkat");
  if (e_self(path)) {
    size_t l = strlen(exe);
    if (l > len) l = len;
    memcpy(buf, exe, l);
    return (ssize_t)l;
  }
  return altro_exe(path, buf, len, vero(dir, path, buf, len));
}

static int script(const char *file, char *const argv[], char *riga, char **nuovi, int max);

// quanti elementi in un elenco argv/envp: gli elenchi nuovi sono grandi quanto serve, sullo stack (niente
// malloc: queste funzioni girano anche nel figlio di un vfork). Prima erano fissi a 1024 e il resto si
// perdeva: il collegatore di cargo con 3000 file oggetto riceveva metà dei file (26 ottobre)
static int quanti(char *const v[]) {
  int n = 0;
  while (v && v[n]) n++;
  return n;
}

// fakechroot non avvia programmi con elenchi di argomenti molto lunghi (risponde EINVAL). Un kernel vero
// direbbe E2BIG, e chi lancia comandi lunghi (rustc, make, xargs) allora passa gli argomenti in un file
// (@file) e riprova: si risponde come il kernel
#define TANTI 1000

static int da_root(const char *path) {
  const char *b = strrchr(path, '/');
  b = b ? b + 1 : path;
  for (int i = 0; DA_ROOT[i]; i++)
    if (!strcmp(b, DA_ROOT[i])) return 1;
  return 0;
}

int execve(const char *path, char *const argv[], char *const envp[]) {
  static int (*vero)(const char *, char *const[], char *const[]);
  if (!vero) vero = dlsym(RTLD_NEXT, "execve");
  const char *proot = getenv("TOD_DIRETTO_PROOT");
  // solo se il programma c'è: execvp del glibc prova una cartella del PATH dopo l'altra, e il primo
  // tentativo (/usr/local/sbin/pkexec, che non esiste) finiva in proot e falliva (ArtCraft, 26 ottobre)
  if (path && proot && da_root(path) && access(path, 1) == 0) {   // tod-proot <programma> <argomenti...>
    char *nuovi[quanti(argv) + 3];
    int n = 0;
    nuovi[n++] = (char *)proot;
    nuovi[n++] = (char *)path;
    for (int i = 1; argv && argv[i]; i++) nuovi[n++] = argv[i];
    nuovi[n] = 0;
    // tod-proot è un programma di Termux (Bionic): niente librerie di glibc né fakechroot
    char *amb[quanti(envp) + 1];
    int m = 0;
    for (int i = 0; envp && envp[i]; i++) {
      const char *v = envp[i];
      if (!strncmp(v, "LD_PRELOAD=", 11) || !strncmp(v, "LD_LIBRARY_PATH=", 16) ||
          !strncmp(v, "FAKECHROOT", 10) || !strncmp(v, "GLIBC_TUNABLES=", 15)) continue;
      amb[m++] = (char *)v;
    }
    amb[m] = 0;
    // dritto al kernel: fakechroot lo avvierebbe con il caricatore di glibc
    static long (*sc)(long, ...);
    if (!sc) sc = dlsym(RTLD_NEXT, "syscall");
    return (int)sc(NR_EXECVE, (long)proot, (long)nuovi, (long)amb);
  }
  if (e_self(path)) return vero(exe, argv, envp);
  char riga[256], *script_argv[quanti(argv) + 4];
  int r;
  if (path && script(path, argv, riga, script_argv, quanti(argv) + 4)) r = vero(script_argv[0], script_argv, envp);
  else r = vero(path, argv, envp);
  if (r < 0 && *__errno_location() == 22 && quanti(argv) > TANTI) *__errno_location() = 7;   // EINVAL → E2BIG
  return r;
}

int execv(const char *path, char *const argv[]) { return execve(path, argv, environ); }

// file = "#!interprete [argomento]" → nuovi = interprete, [argomento], file, argv[1...] (come il kernel)
static int script(const char *file, char *const argv[], char *riga, char **nuovi, int max) {
  int fd = open(file, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0;
  ssize_t l = read(fd, riga, 255);   // BINPRM_BUF_SIZE del kernel: 256
  close(fd);
  if (l < 3 || riga[0] != '#' || riga[1] != '!') return 0;
  riga[l] = 0;
  char *p = riga + 2, *fine = p, *arg;
  while (*fine && *fine != '\n') fine++;
  *fine = 0;
  while (fine > p && (fine[-1] == ' ' || fine[-1] == '\t' || fine[-1] == '\r')) *--fine = 0;
  while (*p == ' ' || *p == '\t') p++;
  if (!*p) return 0;
  for (arg = p; *arg && *arg != ' ' && *arg != '\t'; arg++) {}
  int k = 0;
  nuovi[k++] = p;
  if (*arg) {
    *arg++ = 0;
    while (*arg == ' ' || *arg == '\t') arg++;
    if (*arg) nuovi[k++] = arg;
  }
  nuovi[k++] = (char *)file;
  for (int i = 1; argv && argv[i] && k < max - 1; i++) nuovi[k++] = argv[i];
  nuovi[k] = 0;
  return 1;
}

// come execvp: il primo file eseguibile nel PATH (o file stesso, se ha una /)
static const char *cerca(const char *file, char *buf, size_t n) {
  const char *p, *dir;
  if (!file || !*file) return 0;
  for (p = file; *p; p++)
    if (*p == '/') return file;
  dir = getenv("PATH");
  if (!dir) dir = "/usr/local/bin:/usr/bin:/bin";
  while (*dir) {
    size_t l = 0;
    while (dir[l] && dir[l] != ':') l++;
    snprintf(buf, n, "%.*s%s%s", (int)l, dir, l ? "/" : "", file);
    if (access(buf, 1) == 0) return buf;
    dir += l;
    if (*dir == ':') dir++;
  }
  return 0;
}

int execvp(const char *file, char *const argv[]) {
  static int (*vero)(const char *, char *const[]);
  if (!vero) vero = dlsym(RTLD_NEXT, "execvp");
  char buf[4096];
  const char *f = cerca(file, buf, sizeof buf);
  if (f) return execve(f, argv, environ);
  return vero(file, argv);
}

typedef int (*spawn_t)(pid_t *, const char *, const void *, const void *, char *const[], char *const[]);

int posix_spawn(pid_t *pid, const char *path, const void *azioni, const void *attr, char *const argv[],
                char *const envp[]) {
  static spawn_t vero;
  if (!vero) vero = dlsym(RTLD_NEXT, "posix_spawn");
  char riga[256], *nuovi[quanti(argv) + 4];
  int r;
  if (path && script(path, argv, riga, nuovi, quanti(argv) + 4)) r = vero(pid, nuovi[0], azioni, attr, nuovi, envp);
  else r = vero(pid, path, azioni, attr, argv, envp);
  return r == 22 && quanti(argv) > TANTI ? 7 : r;   // posix_spawn rende l'errore, non errno: EINVAL → E2BIG
}

int posix_spawnp(pid_t *pid, const char *file, const void *azioni, const void *attr, char *const argv[],
                 char *const envp[]) {
  static spawn_t vero;
  if (!vero) vero = dlsym(RTLD_NEXT, "posix_spawnp");
  char buf[4096];
  const char *f = cerca(file, buf, sizeof buf);
  if (f) return posix_spawn(pid, f, azioni, attr, argv, envp);
  return vero(pid, file, azioni, attr, argv, envp);
}

// le azioni di posix_spawn le esegue il glibc nel processo figlio con chiamate dirette al kernel, dove
// fakechroot non arriva: ArtCraft Launcher (Rust: Command::current_dir) avviava le app in /usr/bin, il
// figlio non trovava la cartella sul vero Android e usciva con 127 senza partire (26 ottobre). Il glibc
// copia il percorso, quindi basta tradurlo qui
int posix_spawn_file_actions_addchdir_np(void *azioni, const char *path) {
  static int (*vero)(void *, const char *);
  if (!vero) vero = dlsym(RTLD_NEXT, "posix_spawn_file_actions_addchdir_np");
  char buf[4096];
  return vero(azioni, traduci(path, buf, sizeof buf));
}

int posix_spawn_file_actions_addopen(void *azioni, int fd, const char *path, int flag, unsigned int modo) {
  static int (*vero)(void *, int, const char *, int, unsigned int);
  if (!vero) vero = dlsym(RTLD_NEXT, "posix_spawn_file_actions_addopen");
  char buf[4096];
  return vero(azioni, fd, traduci(path, buf, sizeof buf), flag, modo);
}

long syscall(long nr, long a, long b, long c, long d, long e, long f) {
  static long (*vero)(long, ...);
  if (!vero) vero = dlsym(RTLD_NEXT, "syscall");
  if (nr == NR_STATX) {
    char buf[4096];
    return vero(nr, a, (long)traduci((const char *)b, buf, sizeof buf), c, d, e, f);
  }
  return vero(nr, a, b, c, d, e, f);
}
