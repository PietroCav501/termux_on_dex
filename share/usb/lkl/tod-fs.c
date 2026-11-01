/* tod-fs.so: i dischi USB come cartelle vere in /media/usb/<nome>, per tutte le app del desktop.
 *
 * Senza root Android non lascia montare niente (né col kernel, né con FUSE). I dischi li legge
 * share/usb/lkl/tod-lkl, che offre ogni partizione con un piccolo server SFTP su $RUN/lkl-<nome>.sock.
 * Questa libreria, caricata con LD_PRELOAD in ogni programma del desktop (Termux e, compilata per glibc,
 * il container Debian), fa esistere /media/usb come cartella: open, read, write, stat, opendir, mkdir,
 * rename, unlink, chdir, mmap, statvfs... sui percorsi lì sotto diventano richieste SFTP a tod-lkl. Niente
 * copie: si legge e si scrive direttamente sul disco. I montaggi (/proc/mounts) non si toccano: GLib se ne
 * accorgerebbe solo con un segnale del kernel, e Esplora file terrebbe dischi già espulsi; i dischi li
 * presenta share/usb/tod-volumi.py, già montati.
 *
 *   /media/usb            le partizioni montate (da $RUN/volumi, prima colonna)
 *   /media/usb/<nome>/... i loro file
 *
 * Un file aperto è un descrittore vero (/dev/null) con accanto il suo stato (handle SFTP, posizione):
 * read, write, lseek, fstat, dup, close... su quel numero passano da qui. TOD_FS_RUN dice dov'è $RUN
 * (nel container /tmp/tod-usb). Quando parte un altro programma (exec: "ls > /media/usb/x/f" della shell) i file
 * del disco rimasti aperti diventano un canale vero del sistema, servito da un piccolo processo "postino" che
 * porta i dati sul disco (o dal disco): il programma nuovo non sa niente di questa libreria e funziona lo stesso.
 * Limite: nel container (glibc) le scritture interne di stdio sui file aperti dalla shell stessa ("echo x > f"
 * nella shell di Debian) non passano di qui; nella shell di Termux sì. */
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
#include <sys/inotify.h>
#include <sys/mman.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <signal.h>
#include <spawn.h>
#include <elf.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>

#define RADICE "/media/usb"
#define LRAD 10

/* ---------- le funzioni vere ---------- */
#define VERA(tipo, nome, ...) \
    static tipo (*vera_##nome)(__VA_ARGS__); \
    if (!vera_##nome) vera_##nome = (tipo (*)(__VA_ARGS__))dlsym(RTLD_NEXT, #nome)

static ssize_t r_read(int fd, void *b, size_t n) { VERA(ssize_t, read, int, void *, size_t); return vera_read(fd, b, n); }
static ssize_t r_write(int fd, const void *b, size_t n) { VERA(ssize_t, write, int, const void *, size_t); return vera_write(fd, b, n); }
static int r_close(int fd) { VERA(int, close, int); return vera_close(fd); }
static int r_open(const char *p, int f, mode_t m) { VERA(int, open, const char *, int, ...); return vera_open(p, f, m); }

/* ---------- configurazione ---------- */
static char run_dir[512];
static int pronto;
static pthread_mutex_t gl = PTHREAD_MUTEX_INITIALIZER;
/* Il processo a cui appartengono le tabelle (file del disco aperti, avvisi). Un figlio di vfork (Python,
 * posix_spawn) condivide la memoria del padre finché non parte il programma nuovo: le sue close() e dup2()
 * non devono toccare le tabelle del padre (spegnevano gli avvisi di Esplora file). Il figlio di un fork vero
 * ha la sua copia: lì si torna padroni appena si apre qualcosa di nostro. */
static pid_t padrone;
#define PADRONE() (getpid() == padrone)
#define DIVENTA_PADRONE() do { pid_t _p = getpid(); if (padrone != _p) padrone = _p; } while (0)

static void avvia(void) {
    if (pronto) return;
    const char *r = getenv("TOD_FS_RUN");
    if (r && *r) snprintf(run_dir, sizeof run_dir, "%s", r);
    else { const char *t = getenv("TMPDIR"); snprintf(run_dir, sizeof run_dir, "%s/tod-usb", t && *t ? t : "/tmp"); }
    pronto = 1;
}

/* ---------- percorsi: virtuale o no ---------- */
static char vcwd[PATH_MAX];   /* cartella di lavoro dentro /media/usb ("" se è una vera) */

struct vf;
static struct vf *trova_fd(int fd);
static const char *percorso_fd(int fd);

static void normalizza(const char *in, char *out, size_t n) {   /* via ".", "..", "//" */
    char tmp[PATH_MAX], *parti[256], *sp;
    int k = 0;
    snprintf(tmp, sizeof tmp, "%s", in);
    for (char *t = strtok_r(tmp, "/", &sp); t && k < 256; t = strtok_r(NULL, "/", &sp)) {
        if (!strcmp(t, ".")) continue;
        if (!strcmp(t, "..")) { if (k) k--; continue; }
        parti[k++] = t;
    }
    size_t l = 0;
    out[0] = 0;
    for (int i = 0; i < k && l < n; i++) l += snprintf(out + l, n - l, "/%s", parti[i]);
    if (!k) snprintf(out, n, "/");
}

static int media_finto(const char *p);

/* descrittori veri aperti su "/" (1) o "/media" (2): "mkdir -p" e "rm -r" di coreutils scendono un pezzo alla
 * volta con openat; da lì "usb" (o "media/usb") porta qui. (Nel container /media esiste davvero: senza questo
 * mkdir -p creava cartelle vere nel container) */
static unsigned char reali[4096];
static unsigned char cwd_reale;   /* la cartella di lavoro vera è "/" (1) o "/media" (2): mkdir -p di Debian fa chdir("/") */
static const char *percorso_reale(int fd) { return fd >= 0 && fd < 4096 ? (reali[fd] == 1 ? "/" : reali[fd] == 2 ? "/media" : NULL) : NULL; }

static int nostro_percorso(const char *v) {   /* /media/usb/..., o /media se in Termux non c'è */
    if (!strncmp(v, RADICE, LRAD) && (!v[LRAD] || v[LRAD] == '/')) return 1;
    return !strcmp(v, "/media") && media_finto(v);
}

/* il percorso (con dirfd per le *at) è sotto /media/usb? allora OUT = assoluto normalizzato e 1 */
static int virtuale(int dirfd, const char *p, char *out, size_t n) {
    if (!p) return 0;
    char tmp[PATH_MAX];
    if (p[0] == '/') {
        if (strncmp(p, "/media", 6)) return 0;   /* la via veloce: quasi tutti i percorsi */
        snprintf(tmp, sizeof tmp, "%s", p);
    } else {
        const char *base = NULL;
        if (dirfd == AT_FDCWD) base = vcwd[0] ? vcwd : cwd_reale == 1 ? "/" : cwd_reale == 2 ? "/media" : NULL;
        else base = percorso_fd(dirfd);
        if (!base && dirfd != AT_FDCWD) base = percorso_reale(dirfd);
        if (!base) return 0;
        snprintf(tmp, sizeof tmp, "%s/%s", base, p);
    }
    normalizza(tmp, out, n);
    if (!nostro_percorso(out)) return 0;   /* (anche ".." fuori da /media/usb: torna un percorso vero) */
    avvia();
    return 1;
}

/* "/media/usb/NOME/resto" → volume NOME, dentro "/resto": 1. 0 = la radice /media/usb, 2 = /media */
static int dividi(const char *v, char *vol, size_t nv, char *dentro, size_t nd) {
    if (strncmp(v, RADICE, LRAD)) return 2;
    const char *q = v + LRAD;
    if (!*q || !strcmp(q, "/")) return 0;
    q++;
    const char *s = strchr(q, '/');
    size_t l = s ? (size_t)(s - q) : strlen(q);
    if (l >= nv) l = nv - 1;
    memcpy(vol, q, l); vol[l] = 0;
    snprintf(dentro, nd, "%s", s ? s : "/");
    return 1;
}

/* ---------- i volumi ($RUN/volumi) ---------- */
static int volume_esiste(const char *nome) {
    char p[600], riga[1024];
    snprintf(p, sizeof p, "%s/volumi", run_dir);
    VERA(FILE *, fopen, const char *, const char *);
    FILE *f = vera_fopen(p, "r");
    if (!f) return 0;
    int ok = 0;
    while (!ok && fgets(riga, sizeof riga, f)) {
        size_t k = strcspn(riga, "\t\n");
        if (k == strlen(nome) && !strncmp(riga, nome, k)) ok = 1;
    }
    fclose(f);
    return ok;
}

static int elenca_volumi(char nomi[][256], int max) {
    char p[600], riga[1024];
    snprintf(p, sizeof p, "%s/volumi", run_dir);
    VERA(FILE *, fopen, const char *, const char *);
    FILE *f = vera_fopen(p, "r");
    if (!f) return 0;
    int n = 0;
    while (n < max && fgets(riga, sizeof riga, f)) {
        size_t k = strcspn(riga, "\t\n");
        if (!k || k >= 256) continue;
        memcpy(nomi[n], riga, k); nomi[n][k] = 0; n++;
    }
    fclose(f);
    return n;
}

static void alias_di(const char *nome, char *out, size_t n) {   /* come alias_of di tod-usb, byte per byte */
    size_t i = 0;
    for (; nome[i] && i + 1 < n; i++) {
        char c = nome[i];
        c = c == ' ' ? '-' : c == '/' ? '_' : (c >= 'A' && c <= 'Z') ? c + 32 : c;
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')) c = '-';
        out[i] = c;
    }
    out[i] = 0;
}

/* ---------- SFTP: connessioni (una per processo e volume) ---------- */
enum { FXP_INIT = 1, FXP_VERSION, FXP_OPEN, FXP_CLOSE, FXP_READ, FXP_WRITE, FXP_LSTAT, FXP_FSTAT, FXP_SETSTAT,
       FXP_FSETSTAT, FXP_OPENDIR, FXP_READDIR, FXP_REMOVE, FXP_MKDIR, FXP_RMDIR, FXP_REALPATH, FXP_STAT, FXP_RENAME,
       FXP_READLINK, FXP_SYMLINK, FXP_STATUS = 101, FXP_HANDLE, FXP_DATA, FXP_NAME, FXP_ATTRS, FXP_EXTENDED = 200,
       FXP_EXTENDED_REPLY };
#define A_SIZE 1
#define A_UIDGID 2
#define A_PERM 4
#define A_TIME 8

struct conn { char vol[256]; int fd; pid_t pid; uint32_t id; pthread_mutex_t m; };
static struct conn conns[64];
static int nconn;

struct buf { unsigned char *p; size_t len, cap, pos; };
static void bn(struct buf *b, size_t n) { if (b->len + n > b->cap) { while (b->len + n > b->cap) b->cap = b->cap ? b->cap * 2 : 1024; b->p = realloc(b->p, b->cap); } }
static void p32(struct buf *b, uint32_t v) { bn(b, 4); for (int i = 3; i >= 0; i--) b->p[b->len++] = v >> (8 * i); }
static void p64(struct buf *b, uint64_t v) { p32(b, v >> 32); p32(b, (uint32_t)v); }
static void pn(struct buf *b, const void *s, size_t n) { p32(b, n); bn(b, n); memcpy(b->p + b->len, s, n); b->len += n; }
static void ps(struct buf *b, const char *s) { pn(b, s, strlen(s)); }
static int g32(struct buf *b, uint32_t *v) { if (b->pos + 4 > b->len) return -1; *v = (uint32_t)b->p[b->pos] << 24 | b->p[b->pos + 1] << 16 | b->p[b->pos + 2] << 8 | b->p[b->pos + 3]; b->pos += 4; return 0; }
static int g64(struct buf *b, uint64_t *v) { uint32_t h, l; if (g32(b, &h) || g32(b, &l)) return -1; *v = (uint64_t)h << 32 | l; return 0; }
static const unsigned char *gn(struct buf *b, uint32_t *n) { if (g32(b, n) || b->pos + *n > b->len) return NULL; const unsigned char *r = b->p + b->pos; b->pos += *n; return r; }

static int tutto(int fd, void *b, size_t n, int scrivi) {
    for (size_t f = 0; f < n;) {
        ssize_t r = scrivi ? r_write(fd, (char *)b + f, n - f) : r_read(fd, (char *)b + f, n - f);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        f += r;
    }
    return 0;
}

static int manda(struct conn *c, uint8_t tipo, uint32_t id, struct buf *corpo) {
    unsigned char h[9];
    uint32_t n = 1 + (tipo == FXP_INIT ? 0 : 4) + (corpo ? corpo->len : 0);
    h[0] = n >> 24; h[1] = n >> 16; h[2] = n >> 8; h[3] = n; h[4] = tipo;
    h[5] = id >> 24; h[6] = id >> 16; h[7] = id >> 8; h[8] = id;
    if (tutto(c->fd, h, tipo == FXP_INIT ? 5 : 9, 1)) return -1;
    if (corpo && corpo->len && tutto(c->fd, corpo->p, corpo->len, 1)) return -1;
    return 0;
}
static int ricevi(struct conn *c, uint8_t *tipo, struct buf *r) {
    unsigned char h[4];
    if (tutto(c->fd, h, 4, 0)) return -1;
    uint32_t n = (uint32_t)h[0] << 24 | h[1] << 16 | h[2] << 8 | h[3];
    if (n < 1 || n > (4u << 20)) return -1;
    r->len = r->pos = 0; bn(r, n);
    if (tutto(c->fd, r->p, n, 0)) return -1;
    r->len = n;
    *tipo = r->p[r->pos++];
    return 0;
}

/* (ri)apre la connessione di C se manca o se è del processo padre (dopo un fork). Con c->m preso */
static int collega(struct conn *c) {
    pid_t me = getpid();
    if (c->fd >= 0 && c->pid == me) return 1;
    if (c->fd >= 0) { r_close(c->fd); c->fd = -1; }
    char a[256], p[800];
    alias_di(c->vol, a, sizeof a);
    snprintf(p, sizeof p, "%s/lkl-%s.sock", run_dir, a);
    int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un sa = {.sun_family = AF_UNIX};
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", p);
    if (s < 0 || connect(s, (struct sockaddr *)&sa, sizeof sa)) { if (s >= 0) r_close(s); return 0; }
    char riga[300]; int k = snprintf(riga, sizeof riga, "VOL %s\n", a);
    c->fd = s; c->pid = me; c->id = 1;
    struct buf b = {0}, r = {0};
    uint8_t t;
    p32(&b, 3);   /* versione 3, dentro il pacchetto INIT */
    if (tutto(s, riga, k, 1) || manda(c, FXP_INIT, 0, &b) || ricevi(c, &t, &r) || t != FXP_VERSION) {
        r_close(s); c->fd = -1; free(b.p); free(r.p); return 0;
    }
    free(b.p); free(r.p);
    return 1;
}

/* Una connessione al volume, già presa (c->m) e collegata; lascia() la rende. Fino a PER_VOL per volume
 * e processo: una lettura lunga (una copia, un'anteprima) non fa aspettare le richieste brevi degli
 * altri thread (la finestra di Esplora file). QUALE >= 0: proprio quella (gli handle SFTP valgono solo
 * sulla connessione che li ha aperti). */
#define PER_VOL 4
static struct conn *prendi(const char *vol, int quale) {
    struct conn *c = NULL;
    pthread_mutex_lock(&gl);
    if (quale >= 0) c = quale < nconn ? &conns[quale] : NULL;
    else {
        int quanti = 0; struct conn *primo = NULL, *libera = NULL;
        for (int i = 0; i < nconn && !libera; i++) {
            if (strcmp(conns[i].vol, vol)) continue;
            quanti++; if (!primo) primo = &conns[i];
            if (pthread_mutex_trylock(&conns[i].m) == 0) libera = &conns[i];
        }
        if (!libera && quanti < PER_VOL && nconn < (int)(sizeof conns / sizeof *conns)) {
            libera = &conns[nconn];
            snprintf(libera->vol, sizeof libera->vol, "%s", vol);
            libera->fd = -1;
            pthread_mutex_init(&libera->m, NULL);
            pthread_mutex_lock(&libera->m);
            nconn++;
        }
        if (libera) {
            pthread_mutex_unlock(&gl);
            if (collega(libera)) return libera;
            pthread_mutex_unlock(&libera->m);
            return NULL;
        }
        c = primo;
    }
    pthread_mutex_unlock(&gl);
    if (!c) return NULL;
    pthread_mutex_lock(&c->m);
    if (collega(c)) return c;
    pthread_mutex_unlock(&c->m);
    return NULL;
}
static void lascia(struct conn *c) { pthread_mutex_unlock(&c->m); }
static int indice(struct conn *c) { return (int)(c - conns); }

/* un errore SFTP in errno: tod-lkl mette "(errno N)" in coda al messaggio */
static int errno_di(struct buf *r) {
    uint32_t code, n;
    if (g32(r, &code)) return EIO;
    const unsigned char *m = gn(r, &n);
    if (m) {
        char t[128]; snprintf(t, sizeof t, "%.*s", (int)(n < 127 ? n : 127), m);
        char *e = strstr(t, "(errno ");
        if (e) { int v = atoi(e + 7); if (v > 0) return v; }
    }
    switch (code) {
    case 0: return 0;
    case 1: return 0;   /* EOF */
    case 2: return ENOENT;
    case 3: return EACCES;
    case 8: return ENOTSUP;
    default: return EIO;
    }
}

/* una richiesta e la sua risposta. TIPO in uscita, R il corpo dopo l'id. -1 se il canale è caduto */
static int chiedi(struct conn *c, uint8_t tipo, struct buf *corpo, uint8_t *rt, struct buf *r) {
    uint32_t id = c->id++;
    if (manda(c, tipo, id, corpo) || ricevi(c, rt, r)) { r_close(c->fd); c->fd = -1; return -1; }
    uint32_t rid;
    g32(r, &rid);
    return 0;
}

/* ---------- attributi e stat ---------- */
struct attr { uint32_t flag, uid, gid, perm, at, mt; uint64_t size; };
static int g_attr(struct buf *b, struct attr *a) {
    memset(a, 0, sizeof *a);
    if (g32(b, &a->flag)) return -1;
    if (a->flag & A_SIZE && g64(b, &a->size)) return -1;
    if (a->flag & A_UIDGID && (g32(b, &a->uid) || g32(b, &a->gid))) return -1;
    if (a->flag & A_PERM && g32(b, &a->perm)) return -1;
    if (a->flag & A_TIME && (g32(b, &a->at) || g32(b, &a->mt))) return -1;
    return 0;
}

static uint64_t hash(const char *s) { uint64_t h = 1469598103934665603ULL; while (*s) h = (h ^ (unsigned char)*s++) * 1099511628211ULL; return h; }

static void riempi_stat(struct stat *st, const char *v, const struct attr *a) {
    memset(st, 0, sizeof *st);
    char vol[256] = "", d[PATH_MAX];
    dividi(v, vol, sizeof vol, d, sizeof d);
    st->st_dev = makedev(0, 0x700 + (hash(vol) & 0xff));
    st->st_ino = hash(v) & 0x7fffffffffffffffULL;
    st->st_mode = a->perm ? a->perm : S_IFDIR | 0755;
    st->st_nlink = S_ISDIR(st->st_mode) ? 2 : 1;
    st->st_uid = getuid(); st->st_gid = getgid();
    st->st_size = a->size;
    st->st_blksize = 65536;
    st->st_blocks = (a->size + 511) / 512;
    st->st_atime = a->at; st->st_mtime = a->mt; st->st_ctime = a->mt;
}

/* piccola cache: ls -l fa readdir e poi stat di ogni file (attributi già arrivati col readdir) */
struct cache { char v[PATH_MAX]; struct attr a; time_t t; int usato; };
static struct cache cache[256];
static int cache_i;
static void cache_metti(const char *v, const struct attr *a) {
    pthread_mutex_lock(&gl);
    struct cache *c = &cache[cache_i++ % 256];
    snprintf(c->v, sizeof c->v, "%s", v); c->a = *a; c->t = time(NULL); c->usato = 1;
    pthread_mutex_unlock(&gl);
}
static int cache_prendi(const char *v, struct attr *a) {
    int ok = 0; time_t ora = time(NULL);
    pthread_mutex_lock(&gl);
    for (int i = 0; i < 256 && !ok; i++)
        if (cache[i].usato && ora - cache[i].t <= 1 && !strcmp(cache[i].v, v)) { *a = cache[i].a; ok = 1; }
    pthread_mutex_unlock(&gl);
    return ok;
}
static void cache_via(void) { pthread_mutex_lock(&gl); for (int i = 0; i < 256; i++) cache[i].usato = 0; pthread_mutex_unlock(&gl); }

/* stat di un percorso virtuale: 0 o -errno */
static int vstat(const char *v, struct attr *a, int segui) {
    char vol[256], d[PATH_MAX];
    memset(a, 0, sizeof *a);
    if (dividi(v, vol, sizeof vol, d, sizeof d) != 1) { a->perm = S_IFDIR | 0755; a->mt = time(NULL); return 0; }
    if (cache_prendi(v, a)) return 0;
    if (!volume_esiste(vol)) return -ENOENT;
    for (int t = 0; t < 2; t++) {
        struct conn *c = prendi(vol, -1);
        if (!c) return -ENOENT;
        struct buf b = {0}, r = {0}; uint8_t rt; int e;
        ps(&b, d);
        if (chiedi(c, segui ? FXP_STAT : FXP_LSTAT, &b, &rt, &r)) { lascia(c); free(b.p); free(r.p); continue; }
        if (rt == FXP_ATTRS) { g_attr(&r, a); e = 0; cache_metti(v, a); }
        else e = -errno_di(&r);
        lascia(c); free(b.p); free(r.p);
        return e;
    }
    return -EIO;
}

/* una richiesta semplice (STATUS in risposta) su un percorso: 0 o -errno. CORPO già con il percorso */
static int vsemplice_su(const char *vol, int quale, uint8_t tipo, struct buf *b) {
    struct conn *c = prendi(vol, quale);
    if (!c) return -ENOENT;
    struct buf r = {0}; uint8_t rt; int e;
    if (chiedi(c, tipo, b, &rt, &r)) e = -EIO;
    else e = rt == FXP_STATUS ? -errno_di(&r) : -EIO;
    lascia(c);
    free(r.p);
    cache_via();
    return e;
}
#define vsemplice(vol, tipo, b) vsemplice_su(vol, -1, tipo, b)

/* ---------- file aperti ---------- */
#define MAXFD 4096
struct vf {
    int usato, dir, ro;
    char v[PATH_MAX];          /* percorso virtuale */
    char vol[256];
    unsigned char h[256]; uint32_t hl;   /* handle SFTP (i file; le cartelle non ne hanno) */
    off_t pos;
    int append, acc;
    int ci;                    /* la connessione dove vale l'handle */
    int *rif;                  /* condiviso tra i dup: chi chiude per ultimo chiude l'handle */
};
static struct vf *tab[MAXFD];

static struct vf *trova_fd(int fd) { return fd >= 0 && fd < MAXFD && tab[fd] && tab[fd]->usato ? tab[fd] : NULL; }
static const char *percorso_fd(int fd) { struct vf *f = trova_fd(fd); return f && f->dir ? f->v : NULL; }

static int segnaposto(int flags) {   /* un descrittore vero, al posto del file */
    int fd = r_open("/dev/null", O_RDWR | (flags & O_CLOEXEC), 0);
    if (fd >= MAXFD) { r_close(fd); errno = EMFILE; return -1; }
    return fd;
}

static int vopen(const char *v, int flags, mode_t mode) {
    struct attr a;
    char vol[256], d[PATH_MAX];
    int e = vstat(v, &a, 1);
    int esiste = !e;
    if (e && e != -ENOENT) { errno = -e; return -1; }
    if (esiste && (flags & O_CREAT) && (flags & O_EXCL)) { errno = EEXIST; return -1; }
    if (!esiste && !(flags & O_CREAT)) { errno = ENOENT; return -1; }
    int isdir = esiste && S_ISDIR(a.perm);
    if ((flags & O_DIRECTORY) && esiste && !isdir) { errno = ENOTDIR; return -1; }
    int acc = flags & O_ACCMODE;
    if (isdir && acc != O_RDONLY) { errno = EISDIR; return -1; }
    struct vf *f = calloc(1, sizeof *f);
    f->rif = malloc(sizeof(int)); *f->rif = 1;
    snprintf(f->v, sizeof f->v, "%s", v);
    f->dir = isdir || dividi(v, vol, sizeof vol, d, sizeof d) != 1;
    if (!f->dir) {
        snprintf(f->vol, sizeof f->vol, "%s", vol);
        uint32_t fl = (acc == O_RDONLY ? 1 : acc == O_WRONLY ? 2 : 3) | (flags & O_APPEND ? 4 : 0) |
                      (flags & O_CREAT ? 8 : 0) | (flags & O_TRUNC ? 0x10 : 0) | (flags & O_EXCL ? 0x20 : 0);
        struct buf b = {0}, r = {0}; uint8_t rt;
        ps(&b, d); p32(&b, fl);
        if (flags & O_CREAT) { p32(&b, A_PERM); p32(&b, mode & 07777); } else p32(&b, 0);
        struct conn *c = prendi(vol, -1);
        int err = 0;
        if (!c) err = ENOENT;
        else {
            f->ci = indice(c);
            if (chiedi(c, FXP_OPEN, &b, &rt, &r)) err = EIO;
            else if (rt == FXP_HANDLE) { uint32_t n; const unsigned char *h = gn(&r, &n); if (h && n <= sizeof f->h) { memcpy(f->h, h, n); f->hl = n; } else err = EIO; }
            else { err = errno_di(&r); if (!err) err = EIO; }
            lascia(c);
        }
        free(b.p); free(r.p);
        cache_via();
        if (err) { free(f->rif); free(f); errno = err; return -1; }
        f->append = (flags & O_APPEND) != 0;
        f->acc = acc;
        if (f->append) { struct attr a2; if (!vstat(v, &a2, 1)) f->pos = a2.size; }
    }
    int fd = segnaposto(flags);
    if (fd < 0) { free(f->rif); free(f); return -1; }
    DIVENTA_PADRONE();
    f->usato = 1;
    pthread_mutex_lock(&gl); tab[fd] = f; pthread_mutex_unlock(&gl);
    return fd;
}

static void chiudi_handle(struct vf *f) {
    if (f->dir || !f->hl) return;
    struct buf b = {0}, r = {0}; uint8_t rt;
    pn(&b, f->h, f->hl);
    struct conn *c = prendi(f->vol, f->ci);
    if (c) { chiedi(c, FXP_CLOSE, &b, &rt, &r); lascia(c); }
    free(b.p); free(r.p);
    cache_via();
}

/* letture e scritture: pezzi da 255 KB, più richieste in volo insieme */
#define PEZZO (255 * 1024)
#define VOLO 8
static ssize_t vio(struct vf *f, void *buf, size_t n, off_t off, int scrivi) {
    if (f->dir) { errno = EISDIR; return -1; }
    struct conn *c = prendi(f->vol, f->ci);
    if (!c) { errno = EIO; return -1; }
    size_t fatti = 0; int err = 0, eof = 0;
    while (fatti < n && !err && !eof) {
        int k = 0; size_t quanto[VOLO];
        struct buf b = {0};
        for (; k < VOLO && fatti + (size_t)k * PEZZO < n; k++) {   /* manda */
            size_t da = fatti + (size_t)k * PEZZO;
            quanto[k] = n - da > PEZZO ? PEZZO : n - da;
            b.len = 0;
            pn(&b, f->h, f->hl); p64(&b, off + da);
            if (scrivi) pn(&b, (char *)buf + da, quanto[k]); else p32(&b, quanto[k]);
            if (manda(c, scrivi ? FXP_WRITE : FXP_READ, c->id++, &b)) { err = EIO; break; }
        }
        free(b.p);
        struct buf r = {0};
        for (int i = 0; i < k && err != EIO; i++) {   /* e raccoglie, in ordine */
            uint8_t rt; uint32_t id;
            if (ricevi(c, &rt, &r)) { err = EIO; r_close(c->fd); c->fd = -1; break; }
            g32(&r, &id);
            if (err || eof) continue;
            if (rt == FXP_DATA) {
                uint32_t l; const unsigned char *d = gn(&r, &l);
                if (!d) { err = EIO; continue; }
                memcpy((char *)buf + fatti, d, l);
                fatti += l;
                if (l < quanto[i]) eof = 1;
            } else if (rt == FXP_STATUS) {
                int e = errno_di(&r);
                if (e) err = e; else if (scrivi) fatti += quanto[i]; else eof = 1;
            } else err = EIO;
        }
        free(r.p);
    }
    lascia(c);
    if (scrivi) cache_via();
    if (err && !fatti) { errno = err; return -1; }
    return fatti;
}

/* ---------- open & c. ---------- */
#define MODO(flags) mode_t mode = 0; if ((flags) & (O_CREAT | O_TMPFILE)) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }

static void ricorda_reale(int dirfd, const char *p, int fd) {   /* fd apre "/" o "/media"? */
    if (fd < 0 || fd >= 4096 || !p) return;
    reali[fd] = 0;
    char t[PATH_MAX], n[PATH_MAX];
    const char *base = p[0] == '/' ? "" : dirfd == AT_FDCWD ? NULL : percorso_reale(dirfd);
    if (!base) return;
    snprintf(t, sizeof t, "%s/%s", base, p);
    normalizza(t, n, sizeof n);
    reali[fd] = !strcmp(n, "/") ? 1 : !strcmp(n, "/media") ? 2 : 0;
}
static int apri(int dirfd, const char *p, int flags, mode_t mode, int at) {
    char v[PATH_MAX];
    if (virtuale(dirfd, p, v, sizeof v)) return vopen(v, flags, mode);
    int fd;
    if (at) { VERA(int, openat, int, const char *, int, ...); fd = vera_openat(dirfd, p, flags, mode); }
    else fd = r_open(p, flags, mode);
    if (fd >= 0 && fd < 4096) {
        if ((p[0] == '/' && (!strcmp(p, "/") || !strncmp(p, "/media", 6))) || (p[0] != '/' && percorso_reale(dirfd))) ricorda_reale(dirfd, p, fd);
        else reali[fd] = 0;
    }
    return fd;
}
int open(const char *p, int flags, ...) { MODO(flags); return apri(AT_FDCWD, p, flags, mode, 0); }
int open64(const char *p, int flags, ...) { MODO(flags); return apri(AT_FDCWD, p, flags, mode, 0); }
int openat(int d, const char *p, int flags, ...) { MODO(flags); return apri(d, p, flags, mode, 1); }
int openat64(int d, const char *p, int flags, ...) { MODO(flags); return apri(d, p, flags, mode, 1); }
int __open_2(const char *p, int flags) { return apri(AT_FDCWD, p, flags, 0, 0); }
int __open64_2(const char *p, int flags) { return apri(AT_FDCWD, p, flags, 0, 0); }
int __openat_2(int d, const char *p, int flags) { return apri(d, p, flags, 0, 1); }
int __openat64_2(int d, const char *p, int flags) { return apri(d, p, flags, 0, 1); }
int creat(const char *p, mode_t m) { return apri(AT_FDCWD, p, O_WRONLY | O_CREAT | O_TRUNC, m, 0); }
int creat64(const char *p, mode_t m) { return creat(p, m); }

static int sorvegli_attivi;
static void sorveglio_chiuso(int fd);
int close(int fd) {
    if (!PADRONE()) return r_close(fd);
    if (fd >= 0 && fd < 4096) reali[fd] = 0;
    if (sorvegli_attivi) sorveglio_chiuso(fd);
    struct vf *f = trova_fd(fd);
    if (f) {
        pthread_mutex_lock(&gl); tab[fd] = NULL; pthread_mutex_unlock(&gl);
        if (--*f->rif == 0) { chiudi_handle(f); free(f->rif); }
        free(f);
    }
    return r_close(fd);
}

ssize_t read(int fd, void *b, size_t n) {
    struct vf *f = trova_fd(fd);
    if (!f) return r_read(fd, b, n);
    ssize_t r = vio(f, b, n, f->pos, 0);
    if (r > 0) f->pos += r;
    return r;
}
ssize_t write(int fd, const void *b, size_t n) {
    struct vf *f = trova_fd(fd);
    if (!f) return r_write(fd, b, n);
    if (f->append) { struct attr a; if (!vstat(f->v, &a, 1)) f->pos = a.size; }
    ssize_t r = vio(f, (void *)b, n, f->pos, 1);
    if (r > 0) f->pos += r;
    return r;
}
#define PIO(nome, tipo, scrivi, CV) \
    ssize_t nome(int fd, CV void *b, size_t n, tipo off) { \
        struct vf *f = trova_fd(fd); \
        if (!f) { VERA(ssize_t, nome, int, CV void *, size_t, tipo); return vera_##nome(fd, b, n, off); } \
        return vio(f, (void *)b, n, off, scrivi); }
PIO(pread, off_t, 0, )
PIO(pread64, off64_t, 0, )
PIO(pwrite, off_t, 1, const)
PIO(pwrite64, off64_t, 1, const)

ssize_t readv(int fd, const struct iovec *iov, int n) {
    if (!trova_fd(fd)) { VERA(ssize_t, readv, int, const struct iovec *, int); return vera_readv(fd, iov, n); }
    ssize_t tot = 0;
    for (int i = 0; i < n; i++) { ssize_t r = read(fd, iov[i].iov_base, iov[i].iov_len); if (r < 0) return tot ? tot : -1; tot += r; if ((size_t)r < iov[i].iov_len) break; }
    return tot;
}
ssize_t writev(int fd, const struct iovec *iov, int n) {
    if (!trova_fd(fd)) { VERA(ssize_t, writev, int, const struct iovec *, int); return vera_writev(fd, iov, n); }
    ssize_t tot = 0;
    for (int i = 0; i < n; i++) { ssize_t r = write(fd, iov[i].iov_base, iov[i].iov_len); if (r < 0) return tot ? tot : -1; tot += r; }
    return tot;
}

static off64_t sposta(int fd, off64_t off, int da, const char *vero) {
    struct vf *f = trova_fd(fd);
    if (!f) { off64_t (*g)(int, off64_t, int) = dlsym(RTLD_NEXT, vero); return g(fd, off, da); }
    off64_t n;
    if (da == SEEK_SET) n = off;
    else if (da == SEEK_CUR) n = f->pos + off;
    else if (da == SEEK_END) { struct attr a; int e = vstat(f->v, &a, 1); if (e) { errno = -e; return -1; } n = a.size + off; }
    else { errno = EINVAL; return -1; }
    if (n < 0) { errno = EINVAL; return -1; }
    return f->pos = n;
}
off_t lseek(int fd, off_t o, int d) { return sposta(fd, o, d, "lseek"); }
off64_t lseek64(int fd, off64_t o, int d) { return sposta(fd, o, d, "lseek64"); }

/* dup: lo stesso stato (posizione inclusa, come i dup veri) */
static int copia_fd(int vecchio, int nuovo) {
    if (nuovo >= 0 && nuovo < 4096) reali[nuovo] = vecchio >= 0 && vecchio < 4096 ? reali[vecchio] : 0;
    struct vf *f = trova_fd(vecchio);
    if (!f || nuovo < 0 || nuovo >= MAXFD) return nuovo;
    struct vf *g = malloc(sizeof *g);
    *g = *f; (*f->rif)++;
    pthread_mutex_lock(&gl); tab[nuovo] = g; pthread_mutex_unlock(&gl);
    return nuovo;
}
int dup(int fd) { VERA(int, dup, int); return copia_fd(fd, vera_dup(fd)); }
int dup2(int fd, int n) {
    VERA(int, dup2, int, int);
    if (!PADRONE()) return vera_dup2(fd, n);
    if (n != fd && sorvegli_attivi) sorveglio_chiuso(n);
    if (trova_fd(n) && n != fd) close(n);
    int r = vera_dup2(fd, n);
    return r < 0 || n == fd ? r : copia_fd(fd, r);
}
int dup3(int fd, int n, int fl) {
    VERA(int, dup3, int, int, int);
    if (!PADRONE()) return vera_dup3(fd, n, fl);
    if (n != fd && sorvegli_attivi) sorveglio_chiuso(n);
    if (trova_fd(n) && n != fd) close(n);
    int r = vera_dup3(fd, n, fl);
    return r < 0 ? r : copia_fd(fd, r);
}
int fcntl(int fd, int cmd, ...) {
    va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap);
    VERA(int, fcntl, int, int, ...);
    struct vf *f = trova_fd(fd);
    if (f) {
        if (cmd == F_DUPFD || cmd == F_DUPFD_CLOEXEC) return copia_fd(fd, vera_fcntl(fd, cmd, arg));
        if (cmd == F_GETFL) return f->dir ? O_RDONLY : O_RDWR | (f->append ? O_APPEND : 0);
        if (cmd == F_SETLK || cmd == F_SETLKW || cmd == F_GETLK || cmd == F_OFD_SETLK || cmd == F_OFD_SETLKW || cmd == F_OFD_GETLK) {
            if (cmd == F_GETLK || cmd == F_OFD_GETLK) ((struct flock *)arg)->l_type = F_UNLCK;
            return 0;   /* blocchi sempre concessi (LibreOffice, SQLite) */
        }
    }
    return vera_fcntl(fd, cmd, arg);
}
int flock(int fd, int op) { if (trova_fd(fd)) return 0; VERA(int, flock, int, int); return vera_flock(fd, op); }

static int vsincro(struct vf *f) {
    if (f->dir || !f->hl) return 0;
    struct buf b = {0};
    ps(&b, "fsync@openssh.com"); pn(&b, f->h, f->hl);
    int e = vsemplice_su(f->vol, f->ci, FXP_EXTENDED, &b);
    free(b.p);
    if (e && e != -ENOTSUP) { errno = -e; return -1; }
    return 0;
}
int fsync(int fd) { struct vf *f = trova_fd(fd); if (f) return vsincro(f); VERA(int, fsync, int); return vera_fsync(fd); }
int fdatasync(int fd) { struct vf *f = trova_fd(fd); if (f) return vsincro(f); VERA(int, fdatasync, int); return vera_fdatasync(fd); }

/* SETSTAT su percorso o FSETSTAT su handle */
static int vsetstat(struct vf *f, const char *v, uint32_t flag, uint64_t size, uint32_t perm, uint32_t at, uint32_t mt) {
    char vol[256], d[PATH_MAX];
    struct buf b = {0};
    if (f && !f->dir) { snprintf(vol, sizeof vol, "%s", f->vol); pn(&b, f->h, f->hl); }
    else { if (dividi(v, vol, sizeof vol, d, sizeof d) != 1) return -EPERM; ps(&b, d); }
    p32(&b, flag);
    if (flag & A_SIZE) p64(&b, size);
    if (flag & A_PERM) p32(&b, perm);
    if (flag & A_TIME) { p32(&b, at); p32(&b, mt); }
    int e = f && !f->dir ? vsemplice_su(vol, f->ci, FXP_FSETSTAT, &b) : vsemplice(vol, FXP_SETSTAT, &b);
    free(b.p);
    return e;
}
#define RITORNA(e) do { int _e = (e); if (_e) { errno = -_e; return -1; } return 0; } while (0)

int ftruncate(int fd, off_t l) { struct vf *f = trova_fd(fd); if (f) RITORNA(vsetstat(f, f->v, A_SIZE, l, 0, 0, 0)); VERA(int, ftruncate, int, off_t); return vera_ftruncate(fd, l); }
int ftruncate64(int fd, off64_t l) { struct vf *f = trova_fd(fd); if (f) RITORNA(vsetstat(f, f->v, A_SIZE, l, 0, 0, 0)); VERA(int, ftruncate64, int, off64_t); return vera_ftruncate64(fd, l); }
int truncate(const char *p, off_t l) { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) RITORNA(vsetstat(NULL, v, A_SIZE, l, 0, 0, 0)); VERA(int, truncate, const char *, off_t); return vera_truncate(p, l); }
int truncate64(const char *p, off64_t l) { return truncate(p, l); }
int fchmod(int fd, mode_t m) { struct vf *f = trova_fd(fd); if (f) { vsetstat(f, f->v, A_PERM, 0, m & 07777, 0, 0); return 0; } VERA(int, fchmod, int, mode_t); return vera_fchmod(fd, m); }
int fchmodat(int d, const char *p, mode_t m, int fl) { char v[PATH_MAX]; if (virtuale(d, p, v, sizeof v)) { vsetstat(NULL, v, A_PERM, 0, m & 07777, 0, 0); return 0; } VERA(int, fchmodat, int, const char *, mode_t, int); return vera_fchmodat(d, p, m, fl); }
int chmod(const char *p, mode_t m) { return fchmodat(AT_FDCWD, p, m, 0); }
/* proprietario: sui dischi USB non conta (FAT/exFAT non lo hanno): sempre riuscito */
int fchownat(int d, const char *p, uid_t u, gid_t g, int fl) { char v[PATH_MAX]; if (virtuale(d, p, v, sizeof v)) return 0; VERA(int, fchownat, int, const char *, uid_t, gid_t, int); return vera_fchownat(d, p, u, g, fl); }
int chown(const char *p, uid_t u, gid_t g) { return fchownat(AT_FDCWD, p, u, g, 0); }
int lchown(const char *p, uid_t u, gid_t g) { return fchownat(AT_FDCWD, p, u, g, AT_SYMLINK_NOFOLLOW); }
int fchown(int fd, uid_t u, gid_t g) { if (trova_fd(fd)) return 0; VERA(int, fchown, int, uid_t, gid_t); return vera_fchown(fd, u, g); }

static int vtempi(struct vf *f, const char *v, const struct timespec t[2]) {
    struct timespec ora; clock_gettime(CLOCK_REALTIME, &ora);
    uint32_t at = !t || t[0].tv_nsec == UTIME_NOW ? ora.tv_sec : t[0].tv_sec, mt = !t || t[1].tv_nsec == UTIME_NOW ? ora.tv_sec : t[1].tv_sec;
    if (t && t[1].tv_nsec == UTIME_OMIT) { struct attr a; if (!vstat(v, &a, 1)) mt = a.mt; }
    if (t && t[0].tv_nsec == UTIME_OMIT) { struct attr a; if (!vstat(v, &a, 1)) at = a.at; }
    return vsetstat(f, v, A_TIME, 0, 0, at, mt);
}
int utimensat(int d, const char *p, const struct timespec t[2], int fl) {
    char v[PATH_MAX];
    if (!p && trova_fd(d)) { struct vf *f = trova_fd(d); RITORNA(vtempi(f, f->v, t)); }
    if (virtuale(d, p, v, sizeof v)) RITORNA(vtempi(NULL, v, t));
    VERA(int, utimensat, int, const char *, const struct timespec *, int); return vera_utimensat(d, p, t, fl);
}
int futimens(int fd, const struct timespec t[2]) { struct vf *f = trova_fd(fd); if (f) RITORNA(vtempi(f, f->v, t)); VERA(int, futimens, int, const struct timespec *); return vera_futimens(fd, t); }
int utimes(const char *p, const struct timeval tv[2]) {
    char v[PATH_MAX];
    if (virtuale(AT_FDCWD, p, v, sizeof v)) {
        struct timespec t[2];
        if (tv) { for (int i = 0; i < 2; i++) { t[i].tv_sec = tv[i].tv_sec; t[i].tv_nsec = tv[i].tv_usec * 1000; } }
        RITORNA(vtempi(NULL, v, tv ? t : NULL));
    }
    VERA(int, utimes, const char *, const struct timeval *); return vera_utimes(p, tv);
}
int lutimes(const char *p, const struct timeval tv[2]) { return utimes(p, tv); }
int utime(const char *p, const struct utimbuf *u) {
    char v[PATH_MAX];
    if (virtuale(AT_FDCWD, p, v, sizeof v)) {
        struct timespec t[2] = {{u ? u->actime : 0, u ? 0 : UTIME_NOW}, {u ? u->modtime : 0, u ? 0 : UTIME_NOW}};
        RITORNA(vtempi(NULL, v, t));
    }
    VERA(int, utime, const char *, const struct utimbuf *); return vera_utime(p, u);
}

/* ---------- /media: in Termux non c'è; perché "mkdir -p", i selettori di file e la barra del percorso
 * arrivino a /media/usb, è una cartella (con dentro "usb") quando quella vera manca ---------- */
static int media_finto(const char *p) {
    if (!p || strncmp(p, "/media", 6) || (p[6] && strcmp(p + 6, "/"))) return 0;
    /* chiamata diretta al kernel, una volta: access di bionic passa da faccessat, cioè da qui (giro infinito) */
    static int manca = -1;
    if (manca < 0) manca = syscall(SYS_faccessat, AT_FDCWD, "/media", F_OK, 0) != 0;
    return manca;
}
static int st_media(struct stat *st) {
    memset(st, 0, sizeof *st);
    st->st_mode = S_IFDIR | 0755; st->st_nlink = 3; st->st_uid = getuid(); st->st_gid = getgid();
    st->st_dev = makedev(0, 0x6ff); st->st_ino = 2; st->st_blksize = 4096; st->st_mtime = time(NULL);
    return 0;
}

/* ---------- stat ---------- */
static int st_v(const char *v, struct stat *st, int segui) {
    struct attr a; int e = vstat(v, &a, segui);
    if (e) { errno = -e; return -1; }
    riempi_stat(st, v, &a);
    return 0;
}
int fstatat(int d, const char *p, struct stat *st, int fl) {
    char v[PATH_MAX];
    if (p && !*p && (fl & AT_EMPTY_PATH) && trova_fd(d)) return st_v(trova_fd(d)->v, st, 1);
    if (virtuale(d, p, v, sizeof v)) return st_v(v, st, !(fl & AT_SYMLINK_NOFOLLOW));
    if (media_finto(p)) return st_media(st);
    VERA(int, fstatat, int, const char *, struct stat *, int); return vera_fstatat(d, p, st, fl);
}
int stat(const char *p, struct stat *st) { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) return st_v(v, st, 1); if (media_finto(p)) return st_media(st); VERA(int, stat, const char *, struct stat *); return vera_stat(p, st); }
int lstat(const char *p, struct stat *st) { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) return st_v(v, st, 0); if (media_finto(p)) return st_media(st); VERA(int, lstat, const char *, struct stat *); return vera_lstat(p, st); }
int fstat(int fd, struct stat *st) { struct vf *f = trova_fd(fd); if (f) return st_v(f->v, st, 1); VERA(int, fstat, int, struct stat *); return vera_fstat(fd, st); }
#ifdef __GLIBC__
int stat64(const char *p, struct stat64 *st) { return stat(p, (struct stat *)st); }
int lstat64(const char *p, struct stat64 *st) { return lstat(p, (struct stat *)st); }
int fstat64(int fd, struct stat64 *st) { return fstat(fd, (struct stat *)st); }
int fstatat64(int d, const char *p, struct stat64 *st, int fl) { return fstatat(d, p, (struct stat *)st, fl); }
int __xstat(int x, const char *p, struct stat *st) { (void)x; return stat(p, st); }
int __xstat64(int x, const char *p, struct stat64 *st) { (void)x; return stat(p, (struct stat *)st); }
int __lxstat(int x, const char *p, struct stat *st) { (void)x; return lstat(p, st); }
int __lxstat64(int x, const char *p, struct stat64 *st) { (void)x; return lstat(p, (struct stat *)st); }
int __fxstat(int x, int fd, struct stat *st) { (void)x; return fstat(fd, st); }
int __fxstat64(int x, int fd, struct stat64 *st) { (void)x; return fstat(fd, (struct stat *)st); }
int __fxstatat(int x, int d, const char *p, struct stat *st, int fl) { (void)x; return fstatat(d, p, st, fl); }
int __fxstatat64(int x, int d, const char *p, struct stat64 *st, int fl) { (void)x; return fstatat(d, p, (struct stat *)st, fl); }
#endif
#ifdef STATX_BASIC_STATS
int statx(int d, const char *p, int fl, unsigned mask, struct statx *sx) {
    char v[PATH_MAX]; const char *vv = NULL;
    if (p && !*p && (fl & AT_EMPTY_PATH) && trova_fd(d)) vv = trova_fd(d)->v;
    else if (virtuale(d, p, v, sizeof v)) vv = v;
    if (!vv && media_finto(p)) { memset(sx, 0, sizeof *sx); sx->stx_mask = STATX_BASIC_STATS; sx->stx_mode = S_IFDIR | 0755; sx->stx_nlink = 3; return 0; }
    if (vv) {
        struct stat st;
        if (st_v(vv, &st, !(fl & AT_SYMLINK_NOFOLLOW))) return -1;
        memset(sx, 0, sizeof *sx);
        sx->stx_mask = STATX_BASIC_STATS;
        sx->stx_mode = st.st_mode; sx->stx_nlink = st.st_nlink; sx->stx_uid = st.st_uid; sx->stx_gid = st.st_gid;
        sx->stx_size = st.st_size; sx->stx_blksize = st.st_blksize; sx->stx_blocks = st.st_blocks; sx->stx_ino = st.st_ino;
        sx->stx_atime.tv_sec = st.st_atime; sx->stx_mtime.tv_sec = st.st_mtime; sx->stx_ctime.tv_sec = st.st_ctime;
        sx->stx_dev_major = major(st.st_dev); sx->stx_dev_minor = minor(st.st_dev);
        return 0;
    }
    VERA(int, statx, int, const char *, int, unsigned, struct statx *); return vera_statx(d, p, fl, mask, sx);
}
#endif

int faccessat(int d, const char *p, int m, int fl) {
    char v[PATH_MAX];
    if (virtuale(d, p, v, sizeof v)) { struct attr a; RITORNA(vstat(v, &a, 1)); }
    if (media_finto(p)) return 0;
    VERA(int, faccessat, int, const char *, int, int); return vera_faccessat(d, p, m, fl);
}
int access(const char *p, int m) { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) { struct attr a; RITORNA(vstat(v, &a, 1)); } if (media_finto(p)) return 0; VERA(int, access, const char *, int); return vera_access(p, m); }
int euidaccess(const char *p, int m) { return access(p, m); }
int eaccess(const char *p, int m) { return access(p, m); }

/* ---------- cartelle e nomi ---------- */
static int vpercorso_op(uint8_t tipo, const char *v, uint32_t perm) {
    char vol[256], d[PATH_MAX];
    if (dividi(v, vol, sizeof vol, d, sizeof d) != 1 || !strcmp(d, "/")) return tipo == FXP_MKDIR ? -EEXIST : -EPERM;   /* /media/usb e i volumi stessi */
    struct buf b = {0};
    ps(&b, d);
    if (tipo == FXP_MKDIR) { p32(&b, A_PERM); p32(&b, perm & 07777); }
    int e = vsemplice(vol, tipo, &b);
    free(b.p);
    return e;
}
int mkdirat(int dd, const char *p, mode_t m) { char v[PATH_MAX]; if (virtuale(dd, p, v, sizeof v)) RITORNA(vpercorso_op(FXP_MKDIR, v, m)); if (dd == AT_FDCWD && media_finto(p)) { errno = EEXIST; return -1; } VERA(int, mkdirat, int, const char *, mode_t); return vera_mkdirat(dd, p, m); }
int mkdir(const char *p, mode_t m) { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) RITORNA(vpercorso_op(FXP_MKDIR, v, m)); if (media_finto(p)) { errno = EEXIST; return -1; } VERA(int, mkdir, const char *, mode_t); return vera_mkdir(p, m); }
int rmdir(const char *p) { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) RITORNA(vpercorso_op(FXP_RMDIR, v, 0)); VERA(int, rmdir, const char *); return vera_rmdir(p); }
int unlinkat(int dd, const char *p, int fl) {
    char v[PATH_MAX];
    if (virtuale(dd, p, v, sizeof v)) RITORNA(vpercorso_op(fl & AT_REMOVEDIR ? FXP_RMDIR : FXP_REMOVE, v, 0));
    VERA(int, unlinkat, int, const char *, int); return vera_unlinkat(dd, p, fl);
}
int unlink(const char *p) { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) RITORNA(vpercorso_op(FXP_REMOVE, v, 0)); VERA(int, unlink, const char *); return vera_unlink(p); }
int remove(const char *p) {
    char v[PATH_MAX];
    if (virtuale(AT_FDCWD, p, v, sizeof v)) { struct attr a; int e = vstat(v, &a, 0); if (e) RITORNA(e); RITORNA(vpercorso_op(S_ISDIR(a.perm) ? FXP_RMDIR : FXP_REMOVE, v, 0)); }
    VERA(int, remove, const char *); return vera_remove(p);
}

static int vrinomina(const char *v1, const char *v2, unsigned fl) {
    char vol1[256], d1[PATH_MAX], vol2[256], d2[PATH_MAX];
    if (dividi(v1, vol1, sizeof vol1, d1, sizeof d1) != 1 || dividi(v2, vol2, sizeof vol2, d2, sizeof d2) != 1) return -EPERM;
    if (strcmp(vol1, vol2)) return -EXDEV;   /* tra due dischi: chi rinomina copia e cancella da sé */
    struct buf b = {0};
    if (fl & 1 /* RENAME_NOREPLACE */) { ps(&b, d1); ps(&b, d2); int e = vsemplice(vol1, FXP_RENAME, &b); free(b.p); return e; }
    ps(&b, "posix-rename@openssh.com"); ps(&b, d1); ps(&b, d2);   /* come rename(2): sostituisce */
    int e = vsemplice(vol1, FXP_EXTENDED, &b);
    free(b.p);
    return e;
}
int renameat2(int d1, const char *p1, int d2, const char *p2, unsigned fl) {
    char v1[PATH_MAX], v2[PATH_MAX];
    int a = virtuale(d1, p1, v1, sizeof v1), b = virtuale(d2, p2, v2, sizeof v2);
    if (a && b) RITORNA(vrinomina(v1, v2, fl));
    if (a || b) { errno = EXDEV; return -1; }   /* tra il telefono e un disco USB: copia e cancella */
    VERA(int, renameat2, int, const char *, int, const char *, unsigned); return vera_renameat2(d1, p1, d2, p2, fl);
}
int renameat(int d1, const char *p1, int d2, const char *p2) {
    char v1[PATH_MAX], v2[PATH_MAX];
    int a = virtuale(d1, p1, v1, sizeof v1), b = virtuale(d2, p2, v2, sizeof v2);
    if (a && b) RITORNA(vrinomina(v1, v2, 0));
    if (a || b) { errno = EXDEV; return -1; }
    VERA(int, renameat, int, const char *, int, const char *); return vera_renameat(d1, p1, d2, p2);
}
int rename(const char *p1, const char *p2) { return renameat(AT_FDCWD, p1, AT_FDCWD, p2); }

ssize_t readlinkat(int d, const char *p, char *b, size_t n) {
    char v[PATH_MAX];
    if (virtuale(d, p, v, sizeof v)) {
        struct attr a; int e = vstat(v, &a, 0);
        if (e) { errno = -e; return -1; }
        if (!S_ISLNK(a.perm)) { errno = EINVAL; return -1; }
        char vol[256], dd[PATH_MAX]; dividi(v, vol, sizeof vol, dd, sizeof dd);
        struct buf q = {0}, r = {0}; uint8_t rt; ssize_t out = -1;
        ps(&q, dd);
        struct conn *c = prendi(vol, -1);
        if (c) {
            if (!chiedi(c, FXP_READLINK, &q, &rt, &r) && rt == FXP_NAME) {
                uint32_t cnt, l; g32(&r, &cnt);
                const unsigned char *s = gn(&r, &l);
                if (s) { out = l < n ? l : n; memcpy(b, s, out); }
            }
            lascia(c);
        }
        free(q.p); free(r.p);
        if (out < 0) errno = EIO;
        return out;
    }
    VERA(ssize_t, readlinkat, int, const char *, char *, size_t); return vera_readlinkat(d, p, b, n);
}
ssize_t readlink(const char *p, char *b, size_t n) { return readlinkat(AT_FDCWD, p, b, n); }
int symlinkat(const char *dest, int d, const char *p) {
    char v[PATH_MAX];
    if (virtuale(d, p, v, sizeof v)) {
        char vol[256], dd[PATH_MAX];
        if (dividi(v, vol, sizeof vol, dd, sizeof dd) != 1) { errno = EPERM; return -1; }
        struct buf b = {0}; ps(&b, dest); ps(&b, dd);   /* come OpenSSH: prima la destinazione */
        int e = vsemplice(vol, FXP_SYMLINK, &b); free(b.p);
        RITORNA(e);
    }
    VERA(int, symlinkat, const char *, int, const char *); return vera_symlinkat(dest, d, p);
}
int symlink(const char *dest, const char *p) { return symlinkat(dest, AT_FDCWD, p); }
int linkat(int d1, const char *p1, int d2, const char *p2, int fl) {
    char v[PATH_MAX];
    if (virtuale(d1, p1, v, sizeof v) || virtuale(d2, p2, v, sizeof v)) { errno = EPERM; return -1; }   /* FAT & c.: niente link fisici */
    VERA(int, linkat, int, const char *, int, const char *, int); return vera_linkat(d1, p1, d2, p2, fl);
}
int link(const char *p1, const char *p2) { return linkat(AT_FDCWD, p1, AT_FDCWD, p2, 0); }

char *realpath(const char *p, char *out) {
    char v[PATH_MAX];
    if (virtuale(AT_FDCWD, p, v, sizeof v)) {
        struct attr a; int e = vstat(v, &a, 1);
        if (e) { errno = -e; return NULL; }
        if (!out) return strdup(v);
        return strcpy(out, v);
    }
    VERA(char *, realpath, const char *, char *); return vera_realpath(p, out);
}
char *__realpath_chk(const char *p, char *out, size_t n) { (void)n; return realpath(p, out); }
char *canonicalize_file_name(const char *p) { return realpath(p, NULL); }

/* ---------- cartella di lavoro: cd /media/usb/... ---------- */
/* la cartella vera resta quella di riserva ($RUN/cwd, vuota); i figli la riconoscono e, con $PWD sotto
 * /media/usb (la shell lo esporta), ripartono da lì */
static void cwd_riserva(char *out, size_t n) { avvia(); snprintf(out, n, "%s/cwd", run_dir); }

int chdir(const char *p) {
    char v[PATH_MAX];
    if (virtuale(AT_FDCWD, p, v, sizeof v)) {
        struct attr a; int e = vstat(v, &a, 1);
        if (e) { errno = -e; return -1; }
        if (!S_ISDIR(a.perm)) { errno = ENOTDIR; return -1; }
        char r[600]; cwd_riserva(r, sizeof r);
        VERA(int, mkdir, const char *, mode_t); vera_mkdir(r, 0700);
        VERA(int, chdir, const char *); vera_chdir(r);
        snprintf(vcwd, sizeof vcwd, "%s", v);
        return 0;
    }
    VERA(int, chdir, const char *);
    int r = vera_chdir(p);
    if (!r) {
        vcwd[0] = 0;
        char t[PATH_MAX], n[PATH_MAX];
        const char *base = p[0] == '/' ? "" : cwd_reale == 1 ? "/" : cwd_reale == 2 ? "/media" : NULL;
        if (base) { snprintf(t, sizeof t, "%s/%s", base, p); normalizza(t, n, sizeof n); cwd_reale = !strcmp(n, "/") ? 1 : !strcmp(n, "/media") ? 2 : 0; }
        else cwd_reale = 0;
    }
    return r;
}
int fchdir(int fd) {
    struct vf *f = trova_fd(fd);
    if (f) return chdir(f->v);
    VERA(int, fchdir, int); int r = vera_fchdir(fd);
    if (!r) { vcwd[0] = 0; cwd_reale = fd >= 0 && fd < 4096 ? reali[fd] : 0; }
    return r;
}
char *getcwd(char *b, size_t n) {
    if (vcwd[0]) {
        size_t l = strlen(vcwd) + 1;
        if (!b) { b = malloc(n > l ? n : l); if (!b) return NULL; }
        else if (n < l) { errno = ERANGE; return NULL; }
        memcpy(b, vcwd, l);
        return b;
    }
    VERA(char *, getcwd, char *, size_t); return vera_getcwd(b, n);
}
#ifdef __GLIBC__
char *get_current_dir_name(void) { return getcwd(NULL, 0); }
#endif

__attribute__((constructor)) static void inizio(void) {
    padrone = getpid();
    /* (dopo un fork il figlio non usa le connessioni del padre: collega() guarda il pid e ne apre una sua) */
    {
        char c0[PATH_MAX];
        VERA(char *, getcwd, char *, size_t);
        if (vera_getcwd(c0, sizeof c0)) cwd_reale = !strcmp(c0, "/") ? 1 : !strcmp(c0, "/media") ? 2 : 0;
    }
    const char *pwd = getenv("PWD");
    if (!pwd || strncmp(pwd, RADICE, LRAD) || (pwd[LRAD] && pwd[LRAD] != '/')) return;
    char r[600], c[PATH_MAX];
    cwd_riserva(r, sizeof r);
    VERA(char *, getcwd, char *, size_t);
    if (vera_getcwd(c, sizeof c) && !strcmp(c, r)) snprintf(vcwd, sizeof vcwd, "%s", pwd);   /* figlio di chi era lì */
}

/* ---------- elenchi delle cartelle ---------- */
#define MAGIA 0x746f6466u
struct voce { char nome[256]; unsigned char tipo; ino_t ino; };
struct vdir { uint32_t magia; int fd; struct voce *v; int n, i; struct dirent d; struct dirent64 d64; };

static int carica_dir(struct vdir *dd, const char *v) {
    char vol[256], d[PATH_MAX];
    int cap = 64; dd->v = malloc(cap * sizeof *dd->v); dd->n = 0;
    #define AGGIUNGI(N, T) do { if (dd->n == cap) { cap *= 2; dd->v = realloc(dd->v, cap * sizeof *dd->v); } \
        snprintf(dd->v[dd->n].nome, 256, "%s", N); dd->v[dd->n].tipo = T; \
        char _p[PATH_MAX]; snprintf(_p, sizeof _p, "%s/%s", v, N); dd->v[dd->n].ino = hash(_p) & 0x7fffffffffffffffULL; dd->n++; } while (0)
    AGGIUNGI(".", DT_DIR); AGGIUNGI("..", DT_DIR);
    int livello = dividi(v, vol, sizeof vol, d, sizeof d);
    if (livello == 2) { AGGIUNGI("usb", DT_DIR); return 0; }   /* /media (finta) */
    if (livello != 1) {   /* /media/usb: le partizioni */
        static char nomi[64][256];
        int k = elenca_volumi(nomi, 64);
        for (int i = 0; i < k; i++) AGGIUNGI(nomi[i], DT_DIR);
        return 0;
    }
    struct conn *c = prendi(vol, -1);
    if (!c) return -ENOENT;
    struct buf b = {0}, r = {0}; uint8_t rt; int e = 0;
    unsigned char h[256]; uint32_t hl = 0;
    ps(&b, d);
    if (chiedi(c, FXP_OPENDIR, &b, &rt, &r)) e = -EIO;
    else if (rt != FXP_HANDLE) e = -errno_di(&r) ?: -EIO;
    else { uint32_t n; const unsigned char *x = gn(&r, &n); if (x && n <= sizeof h) { memcpy(h, x, n); hl = n; } else e = -EIO; }
    while (!e) {
        b.len = 0; pn(&b, h, hl);
        if (chiedi(c, FXP_READDIR, &b, &rt, &r)) { e = -EIO; break; }
        if (rt != FXP_NAME) break;   /* EOF */
        uint32_t cnt; g32(&r, &cnt);
        for (uint32_t i = 0; i < cnt; i++) {
            uint32_t ln, ll; const unsigned char *nm = gn(&r, &ln); gn(&r, &ll);
            struct attr a; if (!nm || g_attr(&r, &a)) { e = -EIO; break; }
            char nome[256]; snprintf(nome, sizeof nome, "%.*s", (int)(ln < 255 ? ln : 255), nm);
            if (!strcmp(nome, ".") || !strcmp(nome, "..")) continue;
            char pp[PATH_MAX]; snprintf(pp, sizeof pp, "%s/%s", v, nome);
            cache_metti(pp, &a);
            AGGIUNGI(nome, S_ISDIR(a.perm) ? DT_DIR : S_ISLNK(a.perm) ? DT_LNK : DT_REG);
        }
    }
    if (hl) { b.len = 0; pn(&b, h, hl); chiedi(c, FXP_CLOSE, &b, &rt, &r); }
    lascia(c);
    free(b.p); free(r.p);
    return e;
}

static struct vdir *mio_dir(DIR *d) { struct vdir *v = (struct vdir *)d; return v && v->magia == MAGIA ? v : NULL; }

static DIR *vopendir_fd(int fd) {
    struct vf *f = trova_fd(fd);
    if (!f->dir) { errno = ENOTDIR; return NULL; }
    struct vdir *dd = calloc(1, sizeof *dd);
    dd->magia = MAGIA; dd->fd = fd;
    int e = carica_dir(dd, f->v);
    if (e) { free(dd->v); free(dd); errno = -e; return NULL; }
    return (DIR *)dd;
}
/* Elenchi veri con una voce in più: "media" in "/" (Termux: /media è finta) e "usb" in "/media" (container:
 * /media c'è ma vuota). Senza, navigando da "/" in Esplora file i dischi non si trovano. */
struct aggiunta { DIR *d; const char *nome; int dato; struct dirent e; struct dirent64 e64; };
static struct aggiunta aggiunte[16];
static int aggiunte_attive;   /* 1 dalla prima voce in più: prima readdir va dritto, senza lucchetto */
static void aggiungi_voce(DIR *d, int quale) {   /* quale: 1 = "/", 2 = "/media" */
    if (!d) return;
    const char *nome = NULL;
    if (quale == 1 && media_finto("/media")) nome = "media";
    else if (quale == 2 && !media_finto("/media") && syscall(SYS_faccessat, AT_FDCWD, RADICE, F_OK, 0) != 0) nome = "usb";
    if (!nome) return;
    pthread_mutex_lock(&gl);
    for (int i = 0; i < 16; i++) if (!aggiunte[i].d) { aggiunte[i].d = d; aggiunte[i].nome = nome; aggiunte[i].dato = 0; aggiunte_attive = 1; break; }
    pthread_mutex_unlock(&gl);
}
static struct aggiunta *aggiunta_di(DIR *d) {
    for (int i = 0; i < 16; i++) if (aggiunte[i].d == d) return &aggiunte[i];
    return NULL;
}
static int quale_reale(const char *p) {
    char t[PATH_MAX], n[PATH_MAX];
    if (!p) return 0;
    if (p[0] == '/') snprintf(t, sizeof t, "%s", p);
    else { VERA(char *, getcwd, char *, size_t); char c[PATH_MAX]; if (!vera_getcwd(c, sizeof c)) return 0; snprintf(t, sizeof t, "%s/%s", c, p); }
    normalizza(t, n, sizeof n);
    return !strcmp(n, "/") ? 1 : !strcmp(n, "/media") ? 2 : 0;
}

DIR *opendir(const char *p) {
    char v[PATH_MAX];
    if (virtuale(AT_FDCWD, p, v, sizeof v)) {
        int fd = vopen(v, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
        if (fd < 0) return NULL;
        DIR *d = vopendir_fd(fd);
        if (!d) { int e = errno; close(fd); errno = e; }
        return d;
    }
    VERA(DIR *, opendir, const char *);
    DIR *d = vera_opendir(p);
    int q = d && (p[0] != '/' || !strcmp(p, "/") || !strncmp(p, "/media", 6)) ? quale_reale(p) : 0;
    if (q) aggiungi_voce(d, q);
    return d;
}
DIR *fdopendir(int fd) {
    if (trova_fd(fd)) return vopendir_fd(fd);
    VERA(DIR *, fdopendir, int);
    DIR *d = vera_fdopendir(fd);
    if (d && fd >= 0 && fd < 4096 && reali[fd]) aggiungi_voce(d, reali[fd]);
    return d;
}
/* la voce in più, a elenco vero finito (se l'elenco vero non l'aveva già) */
static struct dirent *voce_in_piu(DIR *d, struct dirent *e) {
    pthread_mutex_lock(&gl);
    struct aggiunta *a = aggiunta_di(d);
    if (a && e && !strcmp(e->d_name, a->nome)) a->dato = 1;
    if (a && !e && !a->dato) {
        a->dato = 1;
        memset(&a->e, 0, sizeof a->e);
        a->e.d_ino = 0x6d65646961; a->e.d_type = DT_DIR; a->e.d_reclen = sizeof a->e;
        snprintf(a->e.d_name, sizeof a->e.d_name, "%s", a->nome);
        e = &a->e;
    }
    pthread_mutex_unlock(&gl);
    return e;
}
struct dirent *readdir(DIR *d) {
    struct vdir *v = mio_dir(d);
    if (!v) { VERA(struct dirent *, readdir, DIR *); struct dirent *e = vera_readdir(d); return aggiunte_attive ? voce_in_piu(d, e) : e; }
    if (v->i >= v->n) return NULL;
    struct voce *x = &v->v[v->i++];
    memset(&v->d, 0, sizeof v->d);
    v->d.d_ino = x->ino; v->d.d_type = x->tipo; v->d.d_reclen = sizeof v->d; v->d.d_off = v->i;
    snprintf(v->d.d_name, sizeof v->d.d_name, "%s", x->nome);
    return &v->d;
}
struct dirent64 *readdir64(DIR *d) {
    struct vdir *v = mio_dir(d);
    if (!v) {
        VERA(struct dirent64 *, readdir64, DIR *);
        struct dirent64 *e = vera_readdir64(d);
        if (!aggiunte_attive) return e;
        pthread_mutex_lock(&gl);
        struct aggiunta *a = aggiunta_di(d);
        if (a && e && !strcmp(e->d_name, a->nome)) a->dato = 1;
        if (a && !e && !a->dato) {
            a->dato = 1;
            memset(&a->e64, 0, sizeof a->e64);
            a->e64.d_ino = 0x6d65646961; a->e64.d_type = DT_DIR; a->e64.d_reclen = sizeof a->e64;
            snprintf(a->e64.d_name, sizeof a->e64.d_name, "%s", a->nome);
            e = &a->e64;
        }
        pthread_mutex_unlock(&gl);
        return e;
    }
    struct dirent *e = readdir(d);
    if (!e) return NULL;
    memset(&v->d64, 0, sizeof v->d64);
    v->d64.d_ino = e->d_ino; v->d64.d_type = e->d_type; v->d64.d_reclen = sizeof v->d64; v->d64.d_off = e->d_off;
    snprintf(v->d64.d_name, sizeof v->d64.d_name, "%s", e->d_name);
    return &v->d64;
}
int readdir_r(DIR *d, struct dirent *e, struct dirent **r) {
    if (!mio_dir(d)) {
        VERA(int, readdir_r, DIR *, struct dirent *, struct dirent **);
        int x = vera_readdir_r(d, e, r);
        if (!x && aggiunte_attive) { struct dirent *y = voce_in_piu(d, *r); if (y && y != *r) { memcpy(e, y, sizeof *e); *r = e; } }
        return x;
    }
    struct dirent *x = readdir(d);
    if (x) { memcpy(e, x, sizeof *e); *r = e; } else *r = NULL;
    return 0;
}
int closedir(DIR *d) {
    struct vdir *v = mio_dir(d);
    if (!v) {
        if (aggiunte_attive) { pthread_mutex_lock(&gl); struct aggiunta *a = aggiunta_di(d); if (a) a->d = NULL; pthread_mutex_unlock(&gl); }
        VERA(int, closedir, DIR *); return vera_closedir(d);
    }
    int fd = v->fd; v->magia = 0; free(v->v); free(v);
    return close(fd);
}
int dirfd(DIR *d) { struct vdir *v = mio_dir(d); if (v) return v->fd; VERA(int, dirfd, DIR *); return vera_dirfd(d); }
void rewinddir(DIR *d) {
    struct vdir *v = mio_dir(d); if (v) { v->i = 0; return; }
    if (aggiunte_attive) { pthread_mutex_lock(&gl); struct aggiunta *a = aggiunta_di(d); if (a) a->dato = 0; pthread_mutex_unlock(&gl); }
    VERA(void, rewinddir, DIR *); vera_rewinddir(d);
}
long telldir(DIR *d) { struct vdir *v = mio_dir(d); if (v) return v->i; VERA(long, telldir, DIR *); return vera_telldir(d); }
void seekdir(DIR *d, long l) { struct vdir *v = mio_dir(d); if (v) { v->i = l; return; } VERA(void, seekdir, DIR *, long); vera_seekdir(d, l); }

static int vscandir(const char *p, struct dirent ***lista, int (*sel)(const struct dirent *), int (*cmp)(const struct dirent **, const struct dirent **)) {
    DIR *d = opendir(p);
    if (!d) return -1;
    struct dirent *e, **l = NULL; int n = 0, cap = 0;
    while ((e = readdir(d))) {
        if (sel && !sel(e)) continue;
        if (n == cap) { cap = cap ? cap * 2 : 32; l = realloc(l, cap * sizeof *l); }
        l[n] = malloc(sizeof *e); memcpy(l[n], e, sizeof *e); n++;
    }
    closedir(d);
    if (cmp && n) qsort(l, n, sizeof *l, (int (*)(const void *, const void *))cmp);
    *lista = l;
    return n;
}
int scandir(const char *p, struct dirent ***l, int (*s)(const struct dirent *), int (*c)(const struct dirent **, const struct dirent **)) {
    char v[PATH_MAX];
    if (virtuale(AT_FDCWD, p, v, sizeof v)) return vscandir(v, l, s, c);
    VERA(int, scandir, const char *, struct dirent ***, int (*)(const struct dirent *), int (*)(const struct dirent **, const struct dirent **));
    return vera_scandir(p, l, s, c);
}

/* ---------- stdio: fopen e fdopen su un file del disco ---------- */
static ssize_t c_leggi(void *c, char *b, size_t n) { return read((int)(intptr_t)c, b, n); }
static ssize_t c_scrivi(void *c, const char *b, size_t n) { return write((int)(intptr_t)c, b, n); }
static int c_chiudi(void *c) { return close((int)(intptr_t)c); }
#ifdef __GLIBC__
static int c_cerca(void *c, off64_t *o, int w) { off64_t r = lseek64((int)(intptr_t)c, *o, w); if (r < 0) return -1; *o = r; return 0; }
static FILE *avvolgi(int fd, const char *m) {
    cookie_io_functions_t io = {c_leggi, c_scrivi, c_cerca, c_chiudi};
    return fopencookie((void *)(intptr_t)fd, m, io);
}
#else
static int b_leggi(void *c, char *b, int n) { return c_leggi(c, b, n); }
static int b_scrivi(void *c, const char *b, int n) { return c_scrivi(c, b, n); }
static fpos_t b_cerca(void *c, fpos_t o, int w) { return lseek((int)(intptr_t)c, o, w); }
static FILE *avvolgi(int fd, const char *m) {
    int r = strchr(m, 'r') || strchr(m, '+'), w = strchr(m, 'w') || strchr(m, 'a') || strchr(m, '+');
    return funopen((void *)(intptr_t)fd, r ? b_leggi : NULL, w ? b_scrivi : NULL, b_cerca, c_chiudi);
}
#endif
static int flag_di(const char *m) {
    int f = strchr(m, '+') ? O_RDWR : m[0] == 'r' ? O_RDONLY : O_WRONLY;
    if (m[0] == 'w') f |= O_CREAT | O_TRUNC;
    if (m[0] == 'a') f |= O_CREAT | O_APPEND;
    if (strchr(m, 'x')) f |= O_EXCL;
    if (strchr(m, 'e')) f |= O_CLOEXEC;
    return f;
}
static FILE *fapri(const char *p, const char *m, const char *vero) {
    char v[PATH_MAX];
    if (virtuale(AT_FDCWD, p, v, sizeof v)) {
        int fd = vopen(v, flag_di(m), 0666);
        if (fd < 0) return NULL;
        FILE *f = avvolgi(fd, m);
        if (!f) close(fd);
        return f;
    }
    FILE *(*g)(const char *, const char *) = dlsym(RTLD_NEXT, vero);
    return g(p, m);
}
FILE *fopen(const char *p, const char *m) { return fapri(p, m, "fopen"); }
FILE *fopen64(const char *p, const char *m) { return fapri(p, m, "fopen64"); }
FILE *fdopen(int fd, const char *m) { if (trova_fd(fd)) return avvolgi(fd, m); VERA(FILE *, fdopen, int, const char *); return vera_fdopen(fd, m); }

/* ---------- file temporanei nella cartella del disco (salvataggi "sicuri" di LibreOffice, GLib...) ---------- */
static int vtemp(char *t, int suffisso, int flags) {
    size_t l = strlen(t);
    if (l < (size_t)suffisso + 6 || memcmp(t + l - suffisso - 6, "XXXXXX", 6)) { errno = EINVAL; return -1; }
    static const char az[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (int tent = 0; tent < 100; tent++) {
        uint64_t x = hash(t) ^ ((uint64_t)getpid() << 20) ^ (uint64_t)clock() ^ ((uint64_t)tent * 0x9e3779b97f4a7c15ULL);
        for (int i = 0; i < 6; i++) { t[l - suffisso - 6 + i] = az[x % 62]; x /= 62; }
        int fd = open(t, O_RDWR | O_CREAT | O_EXCL | flags, 0600);
        if (fd >= 0 || errno != EEXIST) return fd;
    }
    errno = EEXIST;
    return -1;
}
#define TEMP(nome, args, chiamata, suff, fl, ...) \
    int nome args { char v[PATH_MAX]; if (virtuale(AT_FDCWD, t, v, sizeof v)) return vtemp(t, suff, fl); \
        VERA(int, nome, __VA_ARGS__); return vera_##nome chiamata; }
TEMP(mkstemp, (char *t), (t), 0, 0, char *)
TEMP(mkostemp, (char *t, int f), (t, f), 0, f, char *, int)
TEMP(mkstemps, (char *t, int s), (t, s), s, 0, char *, int)
TEMP(mkostemps, (char *t, int s, int f), (t, s, f), s, f, char *, int, int)
#ifdef __GLIBC__
TEMP(mkstemp64, (char *t), (t), 0, 0, char *)
TEMP(mkostemp64, (char *t, int f), (t, f), 0, f, char *, int)
#endif

/* ---------- spazio libero ---------- */
static int vspazio(const char *v, uint64_t out[11]) {
    char vol[256], d[PATH_MAX];
    if (dividi(v, vol, sizeof vol, d, sizeof d) != 1) { memset(out, 0, 11 * 8); out[0] = out[1] = 4096; out[10] = 255; return 0; }
    struct buf b = {0}, r = {0}; uint8_t rt; int e = 0;
    ps(&b, "statvfs@openssh.com"); ps(&b, d);
    struct conn *c = prendi(vol, -1);
    if (!c) return -ENOENT;
    if (chiedi(c, FXP_EXTENDED, &b, &rt, &r)) e = -EIO;
    else if (rt == FXP_EXTENDED_REPLY) { for (int i = 0; i < 11; i++) g64(&r, &out[i]); }
    else e = -errno_di(&r) ?: -EIO;
    lascia(c);
    free(b.p); free(r.p);
    return e;
}
static int sv_v(const char *v, struct statvfs *s) {
    uint64_t x[11]; int e = vspazio(v, x);
    if (e) { errno = -e; return -1; }
    memset(s, 0, sizeof *s);
    s->f_bsize = x[0]; s->f_frsize = x[1]; s->f_blocks = x[2]; s->f_bfree = x[3]; s->f_bavail = x[4];
    s->f_files = x[5]; s->f_ffree = x[6]; s->f_favail = x[7]; s->f_fsid = x[8]; s->f_flag = x[9]; s->f_namemax = x[10];
    return 0;
}
static int sf_v(const char *v, struct statfs *s) {
    uint64_t x[11]; int e = vspazio(v, x);
    if (e) { errno = -e; return -1; }
    memset(s, 0, sizeof *s);
    s->f_type = 0x4d44;   /* "MSDOS": un disco rimovibile qualsiasi */
    s->f_bsize = x[0]; s->f_frsize = x[1]; s->f_blocks = x[2]; s->f_bfree = x[3]; s->f_bavail = x[4];
    s->f_files = x[5]; s->f_ffree = x[6]; s->f_namelen = x[10];
    s->f_flags = x[9] & 1 ? ST_RDONLY : 0;
    return 0;
}
int statvfs(const char *p, struct statvfs *s) { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) return sv_v(v, s); VERA(int, statvfs, const char *, struct statvfs *); return vera_statvfs(p, s); }
int fstatvfs(int fd, struct statvfs *s) { struct vf *f = trova_fd(fd); if (f) return sv_v(f->v, s); VERA(int, fstatvfs, int, struct statvfs *); return vera_fstatvfs(fd, s); }
int statfs(const char *p, struct statfs *s) { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) return sf_v(v, s); VERA(int, statfs, const char *, struct statfs *); return vera_statfs(p, s); }
int fstatfs(int fd, struct statfs *s) { struct vf *f = trova_fd(fd); if (f) return sf_v(f->v, s); VERA(int, fstatfs, int, struct statfs *); return vera_fstatfs(fd, s); }
#ifdef __GLIBC__
int statvfs64(const char *p, struct statvfs64 *s) { return statvfs(p, (struct statvfs *)s); }
int fstatvfs64(int fd, struct statvfs64 *s) { return fstatvfs(fd, (struct statvfs *)s); }
int statfs64(const char *p, struct statfs64 *s) { return statfs(p, (struct statfs *)s); }
int fstatfs64(int fd, struct statfs64 *s) { return fstatfs(fd, (struct statfs *)s); }
#endif

/* ---------- mmap: il contenuto in memoria; le scritture condivise tornano sul disco a munmap/msync ---------- */
struct mappa { void *a; size_t n; int fd_dup; off_t off; int scrive; };
static struct mappa mappe[256];
static void *mmap_v(void *a, size_t n, int prot, int fl, int fd, off64_t off) {
    void *m = mmap(a, n, prot | PROT_WRITE, (fl & ~(MAP_SHARED | MAP_SHARED_VALIDATE)) | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) return m;
    ssize_t r = pread64(fd, m, n, off);
    (void)r;
    if (!(prot & PROT_WRITE)) mprotect(m, n, prot);
    if ((fl & MAP_SHARED) && (prot & PROT_WRITE)) {
        pthread_mutex_lock(&gl);
        for (int i = 0; i < 256; i++) if (!mappe[i].a) { mappe[i] = (struct mappa){m, n, dup(fd), off, 1}; break; }
        pthread_mutex_unlock(&gl);
    }
    return m;
}
static void scarica(struct mappa *x) { if (x->a && x->scrive) pwrite64(x->fd_dup, x->a, x->n, x->off); }
void *mmap(void *a, size_t n, int prot, int fl, int fd, off_t off) {
    if (trova_fd(fd)) return mmap_v(a, n, prot, fl, fd, off);
    VERA(void *, mmap, void *, size_t, int, int, int, off_t); return vera_mmap(a, n, prot, fl, fd, off);
}
void *mmap64(void *a, size_t n, int prot, int fl, int fd, off64_t off) {
    if (trova_fd(fd)) return mmap_v(a, n, prot, fl, fd, off);
    VERA(void *, mmap64, void *, size_t, int, int, int, off64_t); return vera_mmap64(a, n, prot, fl, fd, off);
}
int msync(void *a, size_t n, int fl) {
    for (int i = 0; i < 256; i++) if (mappe[i].a == a) scarica(&mappe[i]);
    VERA(int, msync, void *, size_t, int); return vera_msync(a, n, fl);
}
int munmap(void *a, size_t n) {
    for (int i = 0; i < 256; i++) if (mappe[i].a == a) { scarica(&mappe[i]); close(mappe[i].fd_dup); mappe[i].a = NULL; }
    VERA(int, munmap, void *, size_t); return vera_munmap(a, n);
}

/* ---------- copie veloci del kernel: non sui nostri file (chi copia ripiega su read/write) ---------- */
ssize_t copy_file_range(int a, off64_t *oa, int b, off64_t *ob, size_t n, unsigned fl) {
    if (trova_fd(a) || trova_fd(b)) { errno = EXDEV; return -1; }
    VERA(ssize_t, copy_file_range, int, off64_t *, int, off64_t *, size_t, unsigned); return vera_copy_file_range(a, oa, b, ob, n, fl);
}
ssize_t sendfile(int o, int i, off_t *off, size_t n) {
    if (trova_fd(o) || trova_fd(i)) { errno = EINVAL; return -1; }
    VERA(ssize_t, sendfile, int, int, off_t *, size_t); return vera_sendfile(o, i, off, n);
}
ssize_t sendfile64(int o, int i, off64_t *off, size_t n) {
    if (trova_fd(o) || trova_fd(i)) { errno = EINVAL; return -1; }
    VERA(ssize_t, sendfile64, int, int, off64_t *, size_t); return vera_sendfile64(o, i, off, n);
}
ssize_t splice(int a, off64_t *oa, int b, off64_t *ob, size_t n, unsigned fl) {
    if (trova_fd(a) || trova_fd(b)) { errno = EINVAL; return -1; }
    VERA(ssize_t, splice, int, off64_t *, int, off64_t *, size_t, unsigned); return vera_splice(a, oa, b, ob, n, fl);
}
int posix_fadvise(int fd, off_t o, off_t l, int a) { if (trova_fd(fd)) return 0; VERA(int, posix_fadvise, int, off_t, off_t, int); return vera_posix_fadvise(fd, o, l, a); }
int fallocate(int fd, int m, off_t o, off_t l) {
    struct vf *f = trova_fd(fd);
    if (f) {   /* solo "fai spazio" (m = 0): il file cresce */
        if (m) { errno = EOPNOTSUPP; return -1; }
        struct attr a; int e = vstat(f->v, &a, 1); if (e) RITORNA(e);
        if ((uint64_t)(o + l) > a.size) RITORNA(vsetstat(f, f->v, A_SIZE, o + l, 0, 0, 0));
        return 0;
    }
    VERA(int, fallocate, int, int, off_t, off_t); return vera_fallocate(fd, m, o, l);
}
int posix_fallocate(int fd, off_t o, off_t l) { if (trova_fd(fd)) return fallocate(fd, 0, o, l) ? errno : 0; VERA(int, posix_fallocate, int, off_t, off_t); return vera_posix_fallocate(fd, o, l); }

/* ---------- exec: i file del disco ancora aperti passano a un "postino" (vedi in cima) ---------- */
static void postino(struct vf *f, int s, int scrive) {
    signal(SIGPIPE, SIG_IGN);
    /* processo nuovo, connessione nuova: l'handle del padre qui non vale, il file si riapre */
    char vol[256], d[PATH_MAX];
    if (dividi(f->v, vol, sizeof vol, d, sizeof d) != 1) return;
    struct buf q = {0}, r = {0}; uint8_t rt;
    ps(&q, d); p32(&q, scrive ? 2 : 1); p32(&q, 0);
    struct conn *c = prendi(vol, -1);
    if (!c) return;
    f->ci = indice(c);
    int no = chiedi(c, FXP_OPEN, &q, &rt, &r) || rt != FXP_HANDLE;
    lascia(c);
    if (no) return;
    uint32_t n0; const unsigned char *h = gn(&r, &n0);
    if (!h || n0 > sizeof f->h) return;
    memcpy(f->h, h, n0); f->hl = n0;
    free(q.p); free(r.p);
    char *b = malloc(1 << 20);
    off_t pos = f->pos;
    for (;;) {
        ssize_t n;
        if (scrive) {   /* dal programma al disco */
            n = r_read(s, b, 1 << 20);
            if (n <= 0) break;
            if (f->append) { struct attr a; if (!vstat(f->v, &a, 1)) pos = a.size; }
            if (vio(f, b, n, pos, 1) != n) break;
            pos += n;
        } else {   /* dal disco al programma */
            n = vio(f, b, 1 << 20, pos, 0);
            if (n <= 0 || tutto(s, b, n, 1)) break;
            pos += n;
        }
    }
    if (scrive) vsincro(f);
    chiudi_handle(f);
}
static void prima_di_exec(void) {
    for (int fd = 0; fd < MAXFD; fd++) {
        struct vf *f = trova_fd(fd);
        if (!f || f->dir) continue;
        VERA(int, fcntl, int, int, ...);
        if (vera_fcntl(fd, F_GETFD) & FD_CLOEXEC) continue;   /* si chiude da solo */
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv)) continue;
        pid_t p = fork();
        if (p == 0) {   /* doppio fork: il postino non resta figlio (zombie) del programma nuovo */
            if (fork() == 0) { r_close(sv[0]); postino(f, sv[1], f->acc != O_RDONLY); _exit(0); }
            _exit(0);
        }
        r_close(sv[1]);
        if (p > 0) {
            VERA(pid_t, waitpid, pid_t, int *, int); vera_waitpid(p, NULL, 0);
            VERA(int, dup3, int, int, int); vera_dup3(sv[0], fd, 0);   /* al posto del segnaposto, senza CLOEXEC */
        }
        r_close(sv[0]);
        pthread_mutex_lock(&gl); tab[fd] = NULL; pthread_mutex_unlock(&gl);
    }
}
/* Il programma nuovo può essere dell'altro mondo: un programma di Termux (bionic) lanciato da una shell
 * del container, o il contrario. Il linker di bionic si rifiuta di partire con una libreria glibc
 * in LD_PRELOAD (e viceversa), quindi qui si guarda per chi è fatto il programma e si mette la
 * versione giusta di questa libreria, che sta nella stessa cartella. */
enum { MONDO_IGNOTO, MONDO_BIONIC, MONDO_GLIBC };
static int mondo_elf(const char *p, int giri) {
    int fd = r_open(p, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) return MONDO_IGNOTO;
    unsigned char b[4096]; ssize_t n = r_read(fd, b, sizeof b);
    int m = MONDO_IGNOTO;
    if (n > 2 && b[0] == '#' && b[1] == '!' && giri < 3) {   /* script: conta il suo interprete */
        b[n < (ssize_t)sizeof b ? n : (ssize_t)sizeof b - 1] = 0;
        char *q = (char *)b + 2; while (*q == ' ' || *q == '\t') q++;
        char *f = q; while (*f && *f != ' ' && *f != '\t' && *f != '\n') f++;
        char c = *f; *f = 0;
        if (strcmp(q + (strlen(q) > 3 ? strlen(q) - 4 : 0), "/env") == 0 && c != '\n' && c) {
            char *g = f + 1; while (*g == ' ' || *g == '\t') g++;
            char *h = g; while (*h && *h != ' ' && *h != '\t' && *h != '\n') h++; *h = 0;
            const char *path = getenv("PATH");
            char t[PATH_MAX];
            for (const char *d = path ? path : ""; *g && *d; ) {
                const char *e = strchr(d, ':'); size_t l = e ? (size_t)(e - d) : strlen(d);
                snprintf(t, sizeof t, "%.*s/%s", (int)l, d, g);
                if (access(t, X_OK) == 0) { m = mondo_elf(t, giri + 1); break; }
                d = e ? e + 1 : d + l;
            }
            if (m == MONDO_IGNOTO) m = mondo_elf(q, giri + 1);
        } else m = mondo_elf(q, giri + 1);
    } else if (n >= (ssize_t)sizeof(Elf64_Ehdr) && memcmp(b, ELFMAG, SELFMAG) == 0 && b[EI_CLASS] == ELFCLASS64) {
        Elf64_Ehdr *eh = (Elf64_Ehdr *)b;
        for (int i = 0; i < eh->e_phnum; i++) {
            Elf64_Phdr ph;
            VERA(ssize_t, pread, int, void *, size_t, off_t);
            if (vera_pread(fd, &ph, sizeof ph, eh->e_phoff + (off_t)i * eh->e_phentsize) != sizeof ph) break;
            if (ph.p_type != PT_INTERP) continue;
            char in[256] = ""; size_t l = ph.p_filesz < sizeof in - 1 ? ph.p_filesz : sizeof in - 1;
            if (vera_pread(fd, in, l, ph.p_offset) > 0) {
                in[l] = 0;
                if (strstr(in, "/system/bin/linker")) m = MONDO_BIONIC;
                else if (strstr(in, "ld-linux")) m = MONDO_GLIBC;
            }
            break;
        }
    }
    r_close(fd);
    return m;
}
static int mondo_cerca(const char *p) {   /* come execvp: senza '/' si cerca nel PATH */
    if (!p || !*p) return MONDO_IGNOTO;
    if (strchr(p, '/')) return mondo_elf(p, 0);
    const char *path = getenv("PATH");
    char t[PATH_MAX];
    for (const char *d = path ? path : "/bin:/usr/bin"; *d; ) {
        const char *e = strchr(d, ':'); size_t l = e ? (size_t)(e - d) : strlen(d);
        snprintf(t, sizeof t, "%.*s/%s", (int)l, d, p);
        if (access(t, X_OK) == 0) return mondo_elf(t, 0);
        if (!e) break;
        d = e + 1;
    }
    return MONDO_IGNOTO;
}
/* Copia dell'ambiente con LD_PRELOAD adatto al mondo m; NULL se non serve cambiare niente. */
static char **ambiente_per(char *const e[], int m) {
    if (m == MONDO_IGNOTO || !e) return NULL;
    const char *voglio = m == MONDO_BIONIC ? "tod-fs.so" : "tod-fs-glibc.so";
    const char *altro = m == MONDO_BIONIC ? "tod-fs-glibc.so" : "tod-fs.so";
    size_t n = 0, k = (size_t)-1;
    for (; e[n]; n++) if (k == (size_t)-1 && strncmp(e[n], "LD_PRELOAD=", 11) == 0) k = n;
    if (k == (size_t)-1) return NULL;
    const char *v = e[k] + 11;
    char nuovo[8192]; size_t o = snprintf(nuovo, sizeof nuovo, "LD_PRELOAD=");
    int cambiato = 0;
    for (const char *s = v; *s; ) {
        while (*s == ':' || *s == ' ') s++;
        if (!*s) break;
        const char *f = s; while (*f && *f != ':' && *f != ' ') f++;
        size_t l = (size_t)(f - s), la = strlen(altro);
        int e_altro = l >= la && memcmp(f - la, altro, la) == 0 && (l == la || f[-la - 1] == '/');
        if (o >= sizeof nuovo - PATH_MAX) return NULL;
        if (o > 11) nuovo[o++] = ':';
        if (e_altro) {
            o += snprintf(nuovo + o, sizeof nuovo - o, "%.*s%s", (int)(l - la), s, voglio);
            cambiato = 1;
        } else { memcpy(nuovo + o, s, l); o += l; nuovo[o] = 0; }
        s = f;
    }
    if (!cambiato) return NULL;
    char **r = malloc((n + 1) * sizeof *r + o + 1);   /* un solo blocco: lista e testo nuovo */
    if (!r) return NULL;
    for (size_t i = 0; i < n; i++) r[i] = e[i];
    r[k] = memcpy((char *)(r + n + 1), nuovo, o + 1); r[n] = NULL;
    return r;
}
extern char **environ;
#define CON_AMBIENTE(prog, env, chiamata) do { \
        char *const *E_ = (env); char **N_ = ambiente_per(E_, mondo_cerca(prog)); \
        if (N_) E_ = N_; \
        int r_ = (chiamata); \
        int er_ = errno; free(N_); errno = er_; \
        return r_; } while (0)
int execve(const char *p, char *const a[], char *const e[]) {
    prima_di_exec(); VERA(int, execve, const char *, char *const *, char *const *);
    CON_AMBIENTE(p, e, vera_execve(p, a, E_));
}
int execv(const char *p, char *const a[]) {
    prima_di_exec(); VERA(int, execve, const char *, char *const *, char *const *);
    CON_AMBIENTE(p, environ, vera_execve(p, a, E_));
}
int execvpe(const char *p, char *const a[], char *const e[]) {
    prima_di_exec(); VERA(int, execvpe, const char *, char *const *, char *const *);
    CON_AMBIENTE(p, e, vera_execvpe(p, a, E_));
}
int execvp(const char *p, char *const a[]) {
    prima_di_exec(); VERA(int, execvpe, const char *, char *const *, char *const *);
    CON_AMBIENTE(p, environ, vera_execvpe(p, a, E_));
}
int fexecve(int fd, char *const a[], char *const e[]) { prima_di_exec(); VERA(int, fexecve, int, char *const *, char *const *); return vera_fexecve(fd, a, e); }
int posix_spawn(pid_t *pid, const char *p, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at,
                char *const a[], char *const e[]) {
    VERA(int, posix_spawn, pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const *, char *const *);
    CON_AMBIENTE(p, e, vera_posix_spawn(pid, p, fa, at, a, E_));
}
int posix_spawnp(pid_t *pid, const char *p, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at,
                 char *const a[], char *const e[]) {
    VERA(int, posix_spawnp, pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const *, char *const *);
    CON_AMBIENTE(p, e, vera_posix_spawnp(pid, p, fa, at, a, E_));
}

/* ---------- syscall(): chi chiama il kernel da sé (mv di Termux: renameat2, che bionic per Android 7 non ha) ---------- */
long syscall(long n, ...) {
    va_list ap; va_start(ap, n);
    long a[6]; for (int i = 0; i < 6; i++) a[i] = va_arg(ap, long);
    va_end(ap);
#ifdef SYS_renameat2
    if (n == SYS_renameat2) return renameat2((int)a[0], (const char *)a[1], (int)a[2], (const char *)a[3], (unsigned)a[4]);
#endif
#if defined(SYS_statx) && defined(STATX_BASIC_STATS)
    if (n == SYS_statx) return statx((int)a[0], (const char *)a[1], (int)a[2], (unsigned)a[3], (struct statx *)a[4]);
#endif
#ifdef SYS_faccessat2
    if (n == SYS_faccessat2) { char v[PATH_MAX]; if (virtuale((int)a[0], (const char *)a[1], v, sizeof v)) return faccessat((int)a[0], (const char *)a[1], (int)a[2], 0); }
#endif
    VERA(long, syscall, long, ...);
    return vera_syscall(n, a[0], a[1], a[2], a[3], a[4], a[5]);
}

/* ---------- attributi estesi e notifiche: non ci sono (chi li usa fa senza) ---------- */
#define NOXATTR(tipo, nome, args, chiamata, ...) \
    tipo nome args { char v[PATH_MAX]; if (virtuale(AT_FDCWD, p, v, sizeof v)) { errno = ENOTSUP; return -1; } \
        VERA(tipo, nome, __VA_ARGS__); return vera_##nome chiamata; }
NOXATTR(ssize_t, getxattr, (const char *p, const char *n, void *v_, size_t s), (p, n, v_, s), const char *, const char *, void *, size_t)
NOXATTR(ssize_t, lgetxattr, (const char *p, const char *n, void *v_, size_t s), (p, n, v_, s), const char *, const char *, void *, size_t)
NOXATTR(ssize_t, listxattr, (const char *p, char *l, size_t s), (p, l, s), const char *, char *, size_t)
NOXATTR(ssize_t, llistxattr, (const char *p, char *l, size_t s), (p, l, s), const char *, char *, size_t)
NOXATTR(int, setxattr, (const char *p, const char *n, const void *v_, size_t s, int f), (p, n, v_, s, f), const char *, const char *, const void *, size_t, int)
NOXATTR(int, lsetxattr, (const char *p, const char *n, const void *v_, size_t s, int f), (p, n, v_, s, f), const char *, const char *, const void *, size_t, int)
ssize_t fgetxattr(int fd, const char *n, void *v, size_t s) { if (trova_fd(fd)) { errno = ENOTSUP; return -1; } VERA(ssize_t, fgetxattr, int, const char *, void *, size_t); return vera_fgetxattr(fd, n, v, s); }
ssize_t flistxattr(int fd, char *l, size_t s) { if (trova_fd(fd)) { errno = ENOTSUP; return -1; } VERA(ssize_t, flistxattr, int, char *, size_t); return vera_flistxattr(fd, l, s); }
/* ---------- inotify: Esplora file si aggiorna da sé anche nelle cartelle dei dischi ----------
 * Il kernel non può sorvegliare /media/usb (non esiste davvero). Alla prima cartella del disco sorvegliata,
 * il descrittore inotify del programma diventa un socket (stesso numero): un thread ci passa gli avvisi veri
 * (inotify vero, tenuto a parte) e quelli dei dischi. Per questi ogni mezzo secondo chiede a tod-lkl quante
 * modifiche ci sono state ("tod-cambi", niente disco) e solo se il numero è cambiato rilegge le cartelle e
 * manda IN_CREATE / IN_DELETE / IN_MODIFY+IN_CLOSE_WRITE / IN_DELETE_SELF. Su /media e /media/usb
 * (i volumi) rilegge l'elenco dei volumi, un file in RUN. */
#define WD_BASE 0x40000000
#ifdef __GLIBC__
typedef int wd_t;
#else
typedef uint32_t wd_t;   /* bionic */
#endif
struct elem { char nome[256]; int dir; uint64_t size; uint32_t mt; };
struct osservata { int wd; uint32_t mask; char v[PATH_MAX]; char vol[256]; int livello, file; struct elem *el; int n; uint64_t cambi; struct attr se; };
struct sorveglio { int fd, vero, w, fine, sveglia; pthread_mutex_t m; struct osservata *o[128]; int no, prossimo; };
static struct sorveglio *sorvegli[8];

static int per_nome(const void *a, const void *b) { return strcmp(((const struct elem *)a)->nome, ((const struct elem *)b)->nome); }

/* il contenuto di V: elementi ordinati per nome in *OUT, quanti; -errno. FILE=1 se V è un file (SE i suoi attributi) */
static int istantanea(const char *v, struct elem **out, int *file, struct attr *se) {
    char vol[256], d[PATH_MAX];
    int cap = 64, n = 0;
    struct elem *el = malloc(cap * sizeof *el);
    *out = NULL; *file = 0;
    #define METTI(N, D, S, M) do { if (n == cap) { cap *= 2; el = realloc(el, cap * sizeof *el); } \
        snprintf(el[n].nome, 256, "%s", N); el[n].dir = D; el[n].size = S; el[n].mt = M; n++; } while (0)
    int livello = dividi(v, vol, sizeof vol, d, sizeof d);
    if (livello == 2) METTI("usb", 1, 0, 0);
    else if (livello != 1) {
        static char nomi[64][256]; static pthread_mutex_t mn = PTHREAD_MUTEX_INITIALIZER;
        pthread_mutex_lock(&mn);
        int k = elenca_volumi(nomi, 64);
        for (int i = 0; i < k; i++) METTI(nomi[i], 1, 0, 0);
        pthread_mutex_unlock(&mn);
    } else {
        struct attr a;
        int e = vstat(v, &a, 1);
        if (e) { free(el); return e; }
        if (!S_ISDIR(a.perm)) { *file = 1; *se = a; free(el); return 0; }
        struct conn *c = prendi(vol, -1);
        if (!c) { free(el); return -ENOENT; }
        struct buf b = {0}, r = {0}; uint8_t rt;
        unsigned char h[256]; uint32_t hl = 0;
        ps(&b, d);
        if (chiedi(c, FXP_OPENDIR, &b, &rt, &r)) e = -EIO;
        else if (rt != FXP_HANDLE) e = -errno_di(&r) ?: -EIO;
        else { uint32_t k; const unsigned char *x = gn(&r, &k); if (x && k <= sizeof h) { memcpy(h, x, k); hl = k; } else e = -EIO; }
        while (!e) {
            b.len = 0; pn(&b, h, hl);
            if (chiedi(c, FXP_READDIR, &b, &rt, &r)) { e = -EIO; break; }
            if (rt != FXP_NAME) break;
            uint32_t cnt; g32(&r, &cnt);
            for (uint32_t i = 0; i < cnt; i++) {
                uint32_t ln, ll; const unsigned char *nm = gn(&r, &ln); gn(&r, &ll);
                struct attr at; if (!nm || g_attr(&r, &at)) { e = -EIO; break; }
                char nome[256]; snprintf(nome, sizeof nome, "%.*s", (int)(ln < 255 ? ln : 255), nm);
                if (!strcmp(nome, ".") || !strcmp(nome, "..")) continue;
                METTI(nome, S_ISDIR(at.perm), at.size, at.mt);
            }
        }
        if (hl) { b.len = 0; pn(&b, h, hl); chiedi(c, FXP_CLOSE, &b, &rt, &r); }
        lascia(c);
        free(b.p); free(r.p);
        if (e) { free(el); return e; }
    }
    #undef METTI
    qsort(el, n, sizeof *el, per_nome);
    *out = el;
    return n;
}

static uint64_t cambi_di(const char *vol) {   /* il contatore di tod-lkl; 0 se non risponde */
    struct conn *c = prendi(vol, -1);
    if (!c) return 0;
    struct buf b = {0}, r = {0}; uint8_t rt; uint64_t n = 0;
    ps(&b, "tod-cambi");
    if (!chiedi(c, FXP_EXTENDED, &b, &rt, &r) && rt == FXP_EXTENDED_REPLY) g64(&r, &n);
    lascia(c);
    free(b.p); free(r.p);
    return n;
}

static void avviso(struct sorveglio *s, int wd, uint32_t mask, const char *nome) {
    union { struct inotify_event e; char b[sizeof(struct inotify_event) + 272]; } u;
    memset(&u, 0, sizeof u);
    size_t l = nome ? ((strlen(nome) + 1 + 15) & ~(size_t)15) : 0;
    u.e.wd = wd; u.e.mask = mask; u.e.len = l;
    if (nome) memcpy(u.e.name, nome, strlen(nome));
    ssize_t k = send(s->w, &u, sizeof u.e + l, MSG_NOSIGNAL);   /* piccolo: arriva intero */
    if (getenv("TOD_FS_DEBUG")) fprintf(stderr, "tod-fs: avviso wd %#x maschera %#x %s: %zd (%s)\n", wd, mask, nome ? nome : "", k, k < 0 ? strerror(errno) : "ok");
}

/* confronta il contenuto nuovo con quello di prima e manda gli avvisi. 0 = la sorveglianza è finita */
static int confronta(struct sorveglio *s, struct osservata *o) {
    struct elem *el; int file; struct attr se;
    int n = istantanea(o->v, &el, &file, &se);
    if (n == -ENOENT || (n >= 0 && file != o->file)) {   /* sparita (o diventata un'altra cosa) */
        if (n >= 0) free(el);
        if (o->mask & IN_DELETE_SELF) avviso(s, o->wd, IN_DELETE_SELF, NULL);
        avviso(s, o->wd, IN_IGNORED, NULL);
        return 0;
    }
    if (n < 0) return 1;   /* errore passeggero: si riprova */
    if (getenv("TOD_FS_DEBUG")) fprintf(stderr, "tod-fs: %s: %d -> %d elementi\n", o->v, o->n, n);
    if (file) {
        if (se.size != o->se.size || se.mt != o->se.mt) {
            if (o->mask & IN_MODIFY) avviso(s, o->wd, IN_MODIFY, NULL);
            if (o->mask & IN_CLOSE_WRITE) avviso(s, o->wd, IN_CLOSE_WRITE, NULL);
        }
        o->se = se;
        return 1;
    }
    int i = 0, j = 0;
    while (i < o->n || j < n) {
        int c = i >= o->n ? 1 : j >= n ? -1 : strcmp(o->el[i].nome, el[j].nome);
        if (c < 0) {   /* c'era, non c'è più */
            if (o->mask & IN_DELETE) avviso(s, o->wd, IN_DELETE | (o->el[i].dir ? IN_ISDIR : 0), o->el[i].nome);
            i++;
        } else if (c > 0) {   /* nuovo */
            if (o->mask & IN_CREATE) avviso(s, o->wd, IN_CREATE | (el[j].dir ? IN_ISDIR : 0), el[j].nome);
            j++;
        } else {
            if (!el[j].dir && (el[j].size != o->el[i].size || el[j].mt != o->el[i].mt)) {
                if (o->mask & IN_MODIFY) avviso(s, o->wd, IN_MODIFY, el[j].nome);
                if (o->mask & IN_CLOSE_WRITE) avviso(s, o->wd, IN_CLOSE_WRITE, el[j].nome);
            }
            i++; j++;
        }
    }
    free(o->el); o->el = el; o->n = n;
    return 1;
}

static void *sorveglia_thread(void *x) {
    struct sorveglio *s = x;
    struct timespec ultimo = {0};
    for (;;) {
        struct pollfd pf = {s->vero, POLLIN, 0};
        int r = poll(&pf, 1, 250);
        if (__atomic_load_n(&s->fine, __ATOMIC_ACQUIRE)) break;
        if (r > 0 && (pf.revents & POLLIN)) {
            char b[4096], o[4096];   /* il kernel dà solo avvisi interi */
            ssize_t k = r_read(s->vero, b, sizeof b), n = 0;
            for (ssize_t i = 0; i + (ssize_t)sizeof(struct inotify_event) <= k; ) {   /* senza la sveglia (vedi sotto) */
                struct inotify_event *e = (struct inotify_event *)(b + i);
                size_t l = sizeof *e + e->len;
                if (e->wd != s->sveglia) { memcpy(o + n, e, l); n += l; }
                i += l;
            }
            if (n > 0 && send(s->w, o, n, MSG_NOSIGNAL) < 0) {}
        }
        struct timespec ora; clock_gettime(CLOCK_MONOTONIC, &ora);
        if ((ora.tv_sec - ultimo.tv_sec) * 1000 + (ora.tv_nsec - ultimo.tv_nsec) / 1000000 < 500) continue;
        ultimo = ora;
        pthread_mutex_lock(&s->m);
        for (int i = 0; i < s->no; i++) {
            struct osservata *o = s->o[i];
            if (o->livello == 1) {   /* il disco: solo se tod-lkl dice che è cambiato qualcosa */
                uint64_t c = cambi_di(o->vol);
                if (c && c == o->cambi) continue;
                o->cambi = c;
            }
            if (!confronta(s, o)) { free(o->el); free(o); s->o[i--] = s->o[--s->no]; }
        }
        pthread_mutex_unlock(&s->m);
    }
    r_close(s->vero); r_close(s->w);
    pthread_mutex_destroy(&s->m);
    free(s);
    return NULL;
}

static struct sorveglio *sorveglio_di(int fd) {
    for (int i = 0; i < 8; i++) if (sorvegli[i] && sorvegli[i]->fd == fd) return sorvegli[i];
    return NULL;
}
static struct sorveglio *sorveglio_nuovo(int fd) {   /* con gl preso */
    int slot = -1;
    for (int i = 0; i < 8 && slot < 0; i++) if (!sorvegli[i]) slot = i;
    if (slot < 0) return NULL;
    VERA(int, fcntl, int, int, ...);
    int fl = vera_fcntl(fd, F_GETFL), fdfl = vera_fcntl(fd, F_GETFD);
    if (fl < 0 || fdfl < 0) return NULL;
    int vero = vera_fcntl(fd, F_DUPFD_CLOEXEC, 0), t[2];
    if (vero < 0) return NULL;
    /* socket e non tubo: send(MSG_NOSIGNAL) non manda SIGPIPE se il programma chiude mentre si scrive */
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, t)) { r_close(vero); return NULL; }
    if (fl & O_NONBLOCK) vera_fcntl(t[0], F_SETFL, O_NONBLOCK);
    VERA(int, dup3, int, int, int);
    if (vera_dup3(t[0], fd, fdfl & FD_CLOEXEC ? O_CLOEXEC : 0) < 0) { r_close(t[0]); r_close(t[1]); r_close(vero); return NULL; }
    r_close(t[0]);
    DIVENTA_PADRONE();
    struct sorveglio *s = calloc(1, sizeof *s);
    s->fd = fd; s->vero = vero; s->w = t[1]; s->prossimo = WD_BASE; s->sveglia = -1;
    pthread_mutex_init(&s->m, NULL);
    pthread_t th;
    if (pthread_create(&th, NULL, sorveglia_thread, s)) {   /* senza thread: si rimette com'era */
        vera_dup3(vero, fd, fdfl & FD_CLOEXEC ? O_CLOEXEC : 0); r_close(vero); r_close(t[1]); free(s); return NULL;
    }
    pthread_detach(th);
    sorvegli[slot] = s;
    /* chi sta già aspettando in poll() sul numero FD (il thread di GLib) aspetta ancora il descrittore di prima:
     * un avviso su quello (una sorveglianza aggiunta e tolta, IN_IGNORED) lo sveglia, e il giro dopo aspetta qui */
    VERA(int, inotify_add_watch, int, const char *, uint32_t);
    VERA(int, inotify_rm_watch, int, wd_t);
    s->sveglia = vera_inotify_add_watch(vero, run_dir, IN_ATTRIB);
    if (s->sveglia >= 0) vera_inotify_rm_watch(vero, s->sveglia);
    if (getenv("TOD_FS_DEBUG")) fprintf(stderr, "tod-fs: canale degli avvisi %d: vero %d, scrittura %d\n", fd, vero, t[1]);
    return s;
}
static void sorveglio_chiuso(int fd) {   /* close() del programma: il thread chiude il resto */
    pthread_mutex_lock(&gl);
    for (int i = 0; i < 8; i++)
        if (sorvegli[i] && sorvegli[i]->fd == fd) {
            if (getenv("TOD_FS_DEBUG")) fprintf(stderr, "tod-fs: chiuso il canale degli avvisi %d (pid %d)\n", fd, getpid());
            __atomic_store_n(&sorvegli[i]->fine, 1, __ATOMIC_RELEASE); sorvegli[i] = NULL;
        }
    pthread_mutex_unlock(&gl);
}

int inotify_add_watch(int fd, const char *p, uint32_t m) {
    char v[PATH_MAX];
    VERA(int, inotify_add_watch, int, const char *, uint32_t);
    if (!virtuale(AT_FDCWD, p, v, sizeof v)) {
        struct sorveglio *s = NULL;
        if (sorvegli_attivi) { pthread_mutex_lock(&gl); s = sorveglio_di(fd); pthread_mutex_unlock(&gl); }
        return vera_inotify_add_watch(s ? s->vero : fd, p, m);
    }
    struct osservata *o = calloc(1, sizeof *o);
    snprintf(o->v, sizeof o->v, "%s", v);
    char d[PATH_MAX];
    o->livello = dividi(v, o->vol, sizeof o->vol, d, sizeof d);
    o->mask = m;
    if (o->livello == 1) o->cambi = cambi_di(o->vol);
    int n = istantanea(v, &o->el, &o->file, &o->se);
    if (n < 0) { free(o); errno = -n; return -1; }
    o->n = n;
    if ((m & IN_ONLYDIR) && o->file) { free(o->el); free(o); errno = ENOTDIR; return -1; }
    pthread_mutex_lock(&gl);
    struct sorveglio *s = sorveglio_di(fd);
    if (!s) s = sorveglio_nuovo(fd);
    if (s) sorvegli_attivi = 1;
    pthread_mutex_unlock(&gl);
    if (!s) { free(o->el); free(o); errno = ENOSPC; return -1; }   /* GLib ripiega sul controllo a tempo */
    pthread_mutex_lock(&s->m);
    for (int i = 0; i < s->no; i++)
        if (!strcmp(s->o[i]->v, v)) {   /* già sorvegliata: stesso numero, maschera nuova */
            int wd = s->o[i]->wd;
            s->o[i]->mask = (m & IN_MASK_ADD) ? s->o[i]->mask | m : m;
            pthread_mutex_unlock(&s->m);
            free(o->el); free(o);
            return wd;
        }
    if (s->no >= 128) { pthread_mutex_unlock(&s->m); free(o->el); free(o); errno = ENOSPC; return -1; }
    o->wd = s->prossimo++;
    s->o[s->no++] = o;
    if (getenv("TOD_FS_DEBUG")) fprintf(stderr, "tod-fs: sorveglio %s (wd %#x, maschera %#x, %d elementi)\n", v, o->wd, m, o->n);
    int wd = o->wd;
    pthread_mutex_unlock(&s->m);
    return wd;
}
int inotify_rm_watch(int fd, wd_t wd_) {
    int wd = (int)wd_;
    VERA(int, inotify_rm_watch, int, wd_t);
    if (!sorvegli_attivi) return vera_inotify_rm_watch(fd, wd);
    pthread_mutex_lock(&gl); struct sorveglio *s = sorveglio_di(fd); pthread_mutex_unlock(&gl);
    if (!s) return vera_inotify_rm_watch(fd, wd);
    if (wd < WD_BASE) return vera_inotify_rm_watch(s->vero, wd);
    pthread_mutex_lock(&s->m);
    for (int i = 0; i < s->no; i++)
        if (s->o[i]->wd == wd) {
            free(s->o[i]->el); free(s->o[i]);
            s->o[i] = s->o[--s->no];
            avviso(s, wd, IN_IGNORED, NULL);
            pthread_mutex_unlock(&s->m);
            return 0;
        }
    pthread_mutex_unlock(&s->m);
    errno = EINVAL; return -1;
}
