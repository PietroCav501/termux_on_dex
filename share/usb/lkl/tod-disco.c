/* tod-disco.so: il "disco finto" per i comandi da terminale (fdisk, sfdisk, parted, mkfs.*, fsck.*, e2label,
 * ntfslabel...), caricato con LD_PRELOAD da share/bin/tod-disco.
 *
 * Senza root non esiste /dev/sda: i dischi USB li tiene share/usb/lkl/tod-lkl, uno per disco, che offre il
 * disco "grezzo" su $TOD_DISCHI/lkl-<id>.blk. Qui si fa credere ai programmi che ci siano dei dischi veri:
 *   /dev/sda, /dev/sdb...   i dischi, in ordine di collegamento (usb1, usb2...); /dev/sda1... le partizioni
 *   /proc/partitions         l'elenco come lo scrive il kernel (fdisk -l, blkid e parted lo leggono)
 *   /proc/mounts, /etc/mtab, /proc/self/mountinfo   con le partizioni montate da tod-lkl (in /media/usb/<nome>):
 *                            come su Linux, mkfs e fsck rifiutano una partizione montata
 *   stat, open, read, write, pread, pwrite, lseek, fsync, close, ioctl (dimensione, settori, BLKRRPART...)
 * Aprire un disco per scrivere fa smontare le sue partizioni (tod-lkl); alla chiusura si rileggono e si
 * rimontano. Si compila per Termux (bionic) e per il container Debian (glibc, per ntfs-3g). */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define MAXFD 1024
struct aperto { int usato, disco, part; uint64_t pos, byte; uint32_t settore; };
static struct aperto tab[MAXFD];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

/* ---------- i dischi ---------- */
struct disco { char id[32]; uint64_t byte; int np; struct { int n; uint64_t byte; char fs[16], nome[256]; } p[64]; };
static struct disco dischi[26];
static int ndischi;

static const char *run(void) { const char *r = getenv("TOD_DISCHI"); return r && *r ? r : NULL; }

static int per_id(const void *a, const void *b) {   /* usb2 prima di usb10 */
    const struct disco *x = a, *y = b;
    return atoi(x->id + 3) - atoi(y->id + 3);
}

static int (*vero_open)(const char *, int, ...);
static ssize_t (*vero_read)(int, void *, size_t);
static ssize_t (*vero_write)(int, const void *, size_t);
static int (*vero_close)(int);

#define VERO(nome) (vero_##nome ? vero_##nome : (vero_##nome = dlsym(RTLD_NEXT, #nome)))

static void carica(void) {   /* gli id dai file lkl-<id>.parti (dischi, partizioni, misure) */
    ndischi = 0;
    const char *r = run();
    if (!r) return;
    DIR *d = opendir(r);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) && ndischi < 26) {
        size_t l = strlen(e->d_name);
        if (strncmp(e->d_name, "lkl-", 4) || l < 11 || strcmp(e->d_name + l - 6, ".parti")) continue;
        struct disco *k = &dischi[ndischi];
        memset(k, 0, sizeof *k);
        snprintf(k->id, sizeof k->id, "%.*s", (int)(l - 10), e->d_name + 4);
        char p[PATH_MAX]; snprintf(p, sizeof p, "%s/%s", r, e->d_name);
        FILE *f = fopen(p, "r");
        if (!f) continue;
        char riga[1024];
        while (fgets(riga, sizeof riga, f)) {
            int n; unsigned long long ini, byte;
            if (sscanf(riga, "%d\t%llu\t%llu", &n, &ini, &byte) != 3) continue;
            if (n == 0) { k->byte = byte; continue; }
            if (k->np >= 64) continue;
            /* numero, inizio, byte, fs, etichetta, uuid, nome in Esplora file ("-": non montata) */
            char *c[8] = {0}; int nc = 0;
            riga[strcspn(riga, "\n")] = 0;
            for (char *q = riga; nc < 8; nc++) { c[nc] = q; q = strchr(q, '\t'); if (!q) { nc++; break; } *q++ = 0; }
            k->p[k->np].n = n; k->p[k->np].byte = byte;
            snprintf(k->p[k->np].fs, sizeof k->p[k->np].fs, "%s", nc > 3 ? c[3] : "");
            snprintf(k->p[k->np].nome, sizeof k->p[k->np].nome, "%s", nc > 6 && strcmp(c[6], "-") ? c[6] : "");
            k->np++;
        }
        fclose(f);
        ndischi++;
    }
    closedir(d);
    qsort(dischi, ndischi, sizeof dischi[0], per_id);
}

/* "/dev/sdb2" → disco 1, partizione 2 (0 = disco intero). -1 se non è uno dei nostri */
static int nostro(const char *p, int *disco, int *part) {
    if (!p || strncmp(p, "/dev/sd", 7) || p[7] < 'a' || p[7] > 'z' || !run()) return -1;
    int dk = p[7] - 'a', pt = 0;
    if (p[8]) { char *fine; long v = strtol(p + 8, &fine, 10); if (*fine || v < 1 || v > 64) return -1; pt = v; }
    carica();
    if (dk >= ndischi) return -1;
    if (pt) { int c = 0; for (int i = 0; i < dischi[dk].np; i++) if (dischi[dk].p[i].n == pt) c = 1; if (!c) return -1; }
    *disco = dk; *part = pt;
    return 0;
}

/* ---------- il canale con tod-lkl ---------- */
static int tutto(int fd, void *b, size_t n, int scrivi) {
    for (size_t f = 0; f < n;) {
        ssize_t r = scrivi ? VERO(write)(fd, (char *)b + f, n - f) : VERO(read)(fd, (char *)b + f, n - f);
        if (r <= 0) return -1;
        f += r;
    }
    return 0;
}

static int apri_disco(int dk, int pt, int flags) {
    int rw = (flags & O_ACCMODE) != O_RDONLY;
    int s = socket(AF_UNIX, SOCK_STREAM | ((flags & O_CLOEXEC) ? SOCK_CLOEXEC : 0), 0);
    if (s < 0) return -1;
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s/lkl-%s.blk", run(), dischi[dk].id);
    if (connect(s, (struct sockaddr *)&a, sizeof a)) { VERO(close)(s); errno = ENODEV; return -1; }
    char riga[128]; int k = snprintf(riga, sizeof riga, "APRI %d %d\n", pt, rw);
    if (tutto(s, riga, k, 1)) { VERO(close)(s); errno = EIO; return -1; }
    size_t n = 0;
    while (n < sizeof riga - 1 && VERO(read)(s, riga + n, 1) == 1 && riga[n] != '\n') n++;
    riga[n] = 0;
    unsigned long long byte; unsigned sett; int ro;
    if (strncmp(riga, "OK ", 3) || sscanf(riga + 3, "%llu %u %d", &byte, &sett, &ro) != 3) {
        VERO(close)(s);
        errno = strstr(riga, "protetto") ? EROFS : EBUSY;
        return -1;
    }
    if (s >= MAXFD) { VERO(close)(s); errno = EMFILE; return -1; }
    pthread_mutex_lock(&lock);
    tab[s] = (struct aperto){1, dk, pt, 0, byte, sett};
    pthread_mutex_unlock(&lock);
    return s;
}

static struct aperto *mio(int fd) { return fd >= 0 && fd < MAXFD && tab[fd].usato ? &tab[fd] : NULL; }

static int32_t richiesta(int fd, char op, uint64_t off, uint32_t len, const void *dati, void *risp) {
    unsigned char h[13]; h[0] = op;
    for (int i = 0; i < 8; i++) h[1 + i] = off >> (8 * i);
    for (int i = 0; i < 4; i++) h[9 + i] = len >> (8 * i);
    int32_t e;
    if (tutto(fd, h, 13, 1) || (op == 'W' && tutto(fd, (void *)dati, len, 1)) || tutto(fd, &e, 4, 0)) return -EIO;
    if (op == 'R' && !e && tutto(fd, risp, len, 0)) return -EIO;
    return e;
}

#define PEZZO (1u << 20)
static ssize_t io(int fd, void *b, size_t n, uint64_t off, int scrivi) {
    struct aperto *a = mio(fd);
    if (off >= a->byte) return 0;
    if (off + n > a->byte) n = a->byte - off;
    size_t fatti = 0;
    while (fatti < n) {
        uint32_t k = n - fatti > PEZZO ? PEZZO : (uint32_t)(n - fatti);
        int32_t e = richiesta(fd, scrivi ? 'W' : 'R', off + fatti, k, (char *)b + fatti, (char *)b + fatti);
        if (e) { if (fatti) break; errno = -e; return -1; }
        fatti += k;
    }
    return fatti;
}

/* ---------- /proc/partitions ---------- */
static int partizioni(int flags) {
    carica();
    char buf[16384]; size_t l = 0;
    l += snprintf(buf + l, sizeof buf - l, "major minor  #blocks  name\n\n");
    for (int d = 0; d < ndischi; d++) {
        l += snprintf(buf + l, sizeof buf - l, "%4d %7d %10llu sd%c\n", 8, 16 * d, (unsigned long long)dischi[d].byte / 1024, 'a' + d);
        for (int i = 0; i < dischi[d].np && l < sizeof buf - 64; i++)
            l += snprintf(buf + l, sizeof buf - l, "%4d %7d %10llu sd%c%d\n", 8, 16 * d + dischi[d].p[i].n,
                          (unsigned long long)dischi[d].p[i].byte / 1024, 'a' + d, dischi[d].p[i].n);
    }
    int m = syscall(__NR_memfd_create, "partitions", (flags & O_CLOEXEC) ? 1u /* MFD_CLOEXEC */ : 0u);   /* bionic la dichiara solo da Android 11 */
    if (m < 0) return -1;
    if (tutto(m, buf, l, 1)) { VERO(close)(m); return -1; }
    lseek(m, 0, SEEK_SET);
    return m;
}

/* ---------- i montaggi: quelli veri più le partizioni di tod-lkl ---------- */
static void spazi(char *out, size_t n, const char *in) {   /* come nel kernel: spazio → \040 */
    size_t k = 0;
    for (; *in && k + 5 < n; in++) {
        if (*in == ' ' || *in == '\t' || *in == '\\' || *in == '\n') k += snprintf(out + k, n - k, "\\%03o", (unsigned char)*in);
        else out[k++] = *in;
    }
    out[k] = 0;
}

static int montaggi(const char *p, int flags) {
    int info = strstr(p, "mountinfo") != NULL;
    int m = syscall(__NR_memfd_create, "mounts", (flags & O_CLOEXEC) ? 1u : 0u);
    if (m < 0) return -1;
    int v = VERO(open)(p, O_RDONLY | O_CLOEXEC);
    if (v >= 0) { char b[8192]; ssize_t n; while ((n = VERO(read)(v, b, sizeof b)) > 0) tutto(m, b, n, 1); VERO(close)(v); }
    carica();
    for (int d = 0; d < ndischi; d++)
        for (int i = 0; i < dischi[d].np; i++) {
            if (!*dischi[d].p[i].nome) continue;
            char dove[600], riga[1024], nome[512];
            spazi(nome, sizeof nome, dischi[d].p[i].nome);
            snprintf(dove, sizeof dove, "/media/usb/%s", nome);
            const char *fs = !strcmp(dischi[d].p[i].fs, "ntfs") ? "ntfs3" : dischi[d].p[i].fs;
            int k = info ? snprintf(riga, sizeof riga, "%d 1 8:%d / %s rw,relatime - %s /dev/sd%c%d rw\n", 9000 + 64 * d + i,
                                    16 * d + dischi[d].p[i].n, dove, fs, 'a' + d, dischi[d].p[i].n)
                         : snprintf(riga, sizeof riga, "/dev/sd%c%d %s %s rw,relatime 0 0\n", 'a' + d, dischi[d].p[i].n, dove, fs);
            tutto(m, riga, k, 1);
        }
    lseek(m, 0, SEEK_SET);
    return m;
}
static int e_montaggi(const char *p) {
    return p && (!strcmp(p, "/proc/mounts") || !strcmp(p, "/proc/self/mounts") || !strcmp(p, "/etc/mtab") ||
                 !strcmp(p, "/proc/self/mountinfo") || !strcmp(p, "/data/data/com.termux/files/usr/etc/mtab"));
}

/* ---------- open ---------- */
static int apri(const char *p, int flags, mode_t mode, int dirfd, int at) {
    int dk, pt;
    if (p && !strcmp(p, "/proc/partitions") && run()) return partizioni(flags);
    if (e_montaggi(p) && run()) return montaggi(p, flags);
    if (!nostro(p, &dk, &pt)) return apri_disco(dk, pt, flags);
    if (at) {
        static int (*o)(int, const char *, int, ...);
        if (!o) o = dlsym(RTLD_NEXT, "openat");
        return o(dirfd, p, flags, mode);
    }
    return VERO(open)(p, flags, mode);
}

#define MODO(flags) mode_t mode = 0; if ((flags) & (O_CREAT | O_TMPFILE)) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
int open(const char *p, int flags, ...) { MODO(flags); return apri(p, flags, mode, AT_FDCWD, 0); }
int open64(const char *p, int flags, ...) { MODO(flags); return apri(p, flags, mode, AT_FDCWD, 0); }
int openat(int d, const char *p, int flags, ...) { MODO(flags); return apri(p, flags, mode, d, 1); }
int openat64(int d, const char *p, int flags, ...) { MODO(flags); return apri(p, flags, mode, d, 1); }
int __open_2(const char *p, int flags) { return apri(p, flags, 0, AT_FDCWD, 0); }
int __open64_2(const char *p, int flags) { return apri(p, flags, 0, AT_FDCWD, 0); }
int __openat_2(int d, const char *p, int flags) { return apri(p, flags, 0, d, 1); }
int __openat64_2(int d, const char *p, int flags) { return apri(p, flags, 0, d, 1); }

static FILE *fapri(const char *p, const char *m, const char *vero) {
    int dk, pt;
    if (p && run() && (!strcmp(p, "/proc/partitions") || e_montaggi(p) || !nostro(p, &dk, &pt))) {
        int fd = apri(p, strchr(m, 'w') || strchr(m, '+') ? O_RDWR : O_RDONLY, 0, AT_FDCWD, 0);
        return fd < 0 ? NULL : fdopen(fd, m);
    }
    FILE *(*f)(const char *, const char *) = dlsym(RTLD_NEXT, vero);
    return f(p, m);
}
FILE *fopen(const char *p, const char *m) { return fapri(p, m, "fopen"); }
FILE *setmntent(const char *p, const char *m) { return fapri(p, m, "setmntent"); }
FILE *fopen64(const char *p, const char *m) { return fapri(p, m, "fopen64"); }

/* ---------- letture e scritture ---------- */
ssize_t read(int fd, void *b, size_t n) {
    struct aperto *a = mio(fd);
    if (!a) return VERO(read)(fd, b, n);
    ssize_t r = io(fd, b, n, a->pos, 0);
    if (r > 0) a->pos += r;
    return r;
}
ssize_t write(int fd, const void *b, size_t n) {
    struct aperto *a = mio(fd);
    if (!a) return VERO(write)(fd, b, n);
    ssize_t r = io(fd, (void *)b, n, a->pos, 1);
    if (r > 0) a->pos += r;
    return r;
}
#define PIO(nome, tipo, scrivi, CV) \
    ssize_t nome(int fd, CV void *b, size_t n, tipo off) { \
        if (!mio(fd)) { ssize_t (*f)(int, CV void *, size_t, tipo) = dlsym(RTLD_NEXT, #nome); return f(fd, b, n, off); } \
        return io(fd, (void *)b, n, off, scrivi); }
PIO(pread, off_t, 0, )
PIO(pread64, off64_t, 0, )
PIO(pwrite, off_t, 1, const)
PIO(pwrite64, off64_t, 1, const)

static off64_t sposta(int fd, off64_t off, int da, const char *vero) {
    struct aperto *a = mio(fd);
    if (!a) { off64_t (*f)(int, off64_t, int) = dlsym(RTLD_NEXT, vero); return f(fd, off, da); }
    off64_t n = da == SEEK_SET ? off : da == SEEK_CUR ? (off64_t)a->pos + off : da == SEEK_END ? (off64_t)a->byte + off : -1;
    if (n < 0) { errno = EINVAL; return -1; }
    a->pos = n;
    return n;
}
off_t lseek(int fd, off_t off, int da) { return sposta(fd, off, da, "lseek"); }
off64_t lseek64(int fd, off64_t off, int da) { return sposta(fd, off, da, "lseek64"); }

int close(int fd) {
    struct aperto *a = mio(fd);
    if (a) {
        richiesta(fd, 'Q', 0, 0, NULL, NULL);
        pthread_mutex_lock(&lock); a->usato = 0; pthread_mutex_unlock(&lock);
    }
    return VERO(close)(fd);
}
static int sincro(int fd, const char *vero) {
    if (!mio(fd)) { int (*f)(int) = dlsym(RTLD_NEXT, vero); return f(fd); }
    int32_t e = richiesta(fd, 'F', 0, 0, NULL, NULL);
    if (e) { errno = -e; return -1; }
    return 0;
}
int fsync(int fd) { return sincro(fd, "fsync"); }
int fdatasync(int fd) { return sincro(fd, "fdatasync"); }

/* ---------- stat: dispositivi a blocchi, major 8 come i dischi SCSI/USB ---------- */
static void finto(struct stat *st, int dk, int pt) {
    memset(st, 0, sizeof *st);
    st->st_mode = S_IFBLK | 0660;
    st->st_rdev = makedev(8, 16 * dk + pt);
    st->st_dev = makedev(0, 6);
    st->st_nlink = 1;
    st->st_uid = getuid(); st->st_gid = getgid();
    st->st_blksize = 4096;
}
static int st_nome(const char *p, struct stat *st, const char *vero) {
    int dk, pt;
    if (!nostro(p, &dk, &pt)) { finto(st, dk, pt); return 0; }
    int (*f)(const char *, struct stat *) = dlsym(RTLD_NEXT, vero);
    return f(p, st);
}
int stat(const char *p, struct stat *st) { return st_nome(p, st, "stat"); }
int lstat(const char *p, struct stat *st) { return st_nome(p, st, "lstat"); }
int fstat(int fd, struct stat *st) {
    struct aperto *a = mio(fd);
    if (a) { finto(st, a->disco, a->part); return 0; }
    int (*f)(int, struct stat *) = dlsym(RTLD_NEXT, "fstat");
    return f(fd, st);
}
int fstatat(int d, const char *p, struct stat *st, int fl) {
    int dk, pt;
    if (!nostro(p, &dk, &pt)) { finto(st, dk, pt); return 0; }
    if (p && !*p && (fl & AT_EMPTY_PATH) && mio(d)) return fstat(d, st);
    int (*f)(int, const char *, struct stat *, int) = dlsym(RTLD_NEXT, "fstatat");
    return f(d, p, st, fl);
}
#ifdef __GLIBC__
/* glibc: anche le varianti 64 e quelle vecchie (__xstat) */
int stat64(const char *p, struct stat64 *st) { return stat(p, (struct stat *)st); }
int lstat64(const char *p, struct stat64 *st) { return lstat(p, (struct stat *)st); }
int fstat64(int fd, struct stat64 *st) { return fstat(fd, (struct stat *)st); }
int fstatat64(int d, const char *p, struct stat64 *st, int fl) { return fstatat(d, p, (struct stat *)st, fl); }
int __xstat(int v, const char *p, struct stat *st) { (void)v; return stat(p, st); }
int __xstat64(int v, const char *p, struct stat64 *st) { (void)v; return stat(p, (struct stat *)st); }
int __lxstat(int v, const char *p, struct stat *st) { (void)v; return lstat(p, st); }
int __lxstat64(int v, const char *p, struct stat64 *st) { (void)v; return lstat(p, (struct stat *)st); }
int __fxstat(int v, int fd, struct stat *st) { (void)v; return fstat(fd, st); }
int __fxstat64(int v, int fd, struct stat64 *st) { (void)v; return fstat(fd, (struct stat *)st); }
int statx(int d, const char *p, int fl, unsigned mask, struct statx *sx) {
    int dk, pt;
    struct aperto *a = p && !*p && (fl & AT_EMPTY_PATH) ? mio(d) : NULL;
    if (a || !nostro(p, &dk, &pt)) {
        if (a) { dk = a->disco; pt = a->part; }
        memset(sx, 0, sizeof *sx);
        sx->stx_mask = STATX_BASIC_STATS;
        sx->stx_mode = S_IFBLK | 0660; sx->stx_nlink = 1; sx->stx_blksize = 4096;
        sx->stx_uid = getuid(); sx->stx_gid = getgid();
        sx->stx_rdev_major = 8; sx->stx_rdev_minor = 16 * dk + pt;
        return 0;
    }
    int (*f)(int, const char *, int, unsigned, struct statx *) = dlsym(RTLD_NEXT, "statx");
    return f(d, p, fl, mask, sx);
}
#endif

int access(const char *p, int m) {
    int dk, pt;
    if (!nostro(p, &dk, &pt)) return 0;
    int (*f)(const char *, int) = dlsym(RTLD_NEXT, "access");
    return f(p, m);
}
char *realpath(const char *p, char *out) {
    int dk, pt;
    if (!nostro(p, &dk, &pt)) { if (!out) return strdup(p); return strcpy(out, p); }
    char *(*f)(const char *, char *) = dlsym(RTLD_NEXT, "realpath");
    return f(p, out);
}

/* ---------- ioctl dei dischi ---------- */
#define BLKROGET 0x125e
#define BLKRRPART 0x125f
#define BLKGETSIZE 0x1260
#define BLKFLSBUF 0x1261
#define BLKSSZGET 0x1268
#define BLKBSZGET 0x80081270
#define BLKGETSIZE64 0x80081272
#define BLKDISCARD 0x1277
#define BLKIOMIN 0x1278
#define BLKIOOPT 0x1279
#define BLKALIGNOFF 0x127a
#define BLKPBSZGET 0x127b
#define BLKDISCARDZEROES 0x127c
#define HDIO_GETGEO 0x0301

static int io_disco(int fd, unsigned long req, void *arg) {
    struct aperto *a = mio(fd);
    switch ((unsigned)req) {
    case BLKGETSIZE64: *(uint64_t *)arg = a->byte; return 0;
    case BLKGETSIZE: *(unsigned long *)arg = a->byte / 512; return 0;
    case BLKSSZGET: *(int *)arg = a->settore; return 0;
    case BLKPBSZGET: case BLKIOMIN: *(unsigned *)arg = a->settore; return 0;
    case BLKBSZGET: *(int *)arg = 4096; return 0;
    case BLKIOOPT: case BLKALIGNOFF: case BLKDISCARDZEROES: *(int *)arg = 0; return 0;
    case BLKROGET: *(int *)arg = 0; return 0;
    case BLKFLSBUF: { int32_t e = richiesta(fd, 'F', 0, 0, NULL, NULL); if (e) { errno = -e; return -1; } return 0; }
    case BLKRRPART: richiesta(fd, 'P', 0, 0, NULL, NULL); return 0;   /* la rilegge tod-lkl alla chiusura */
    case HDIO_GETGEO: {   /* geometria finta, come per le chiavette: 255 testine, 63 settori */
        struct { unsigned char heads, sectors; unsigned short cyl; unsigned long start; } *g = arg;
        g->heads = 255; g->sectors = 63; g->cyl = a->byte / 512 / (255 * 63); g->start = 0;
        return 0;
    }
    case BLKDISCARD: default: errno = ENOTTY; return -1;
    }
}
#ifdef __BIONIC__
int ioctl(int fd, int req, ...) {
#else
int ioctl(int fd, unsigned long req, ...) {
#endif
    va_list ap; va_start(ap, req); void *arg = va_arg(ap, void *); va_end(ap);
    if (mio(fd)) return io_disco(fd, (unsigned long)(unsigned)req, arg);
#ifdef __BIONIC__
    int (*f)(int, int, ...) = dlsym(RTLD_NEXT, "ioctl");
#else
    int (*f)(int, unsigned long, ...) = dlsym(RTLD_NEXT, "ioctl");
#endif
    return f(fd, req, arg);
}
