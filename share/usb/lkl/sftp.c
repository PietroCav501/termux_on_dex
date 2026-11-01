/* Server SFTP (versione 3, quella di OpenSSH e di gvfs) sopra le chiamate di LKL, incluso da tod-lkl.c.
 * I programmi del desktop lo raggiungono con tod-fs.so: "VOL <nome>\n" e poi il flusso sftp. La radice
 * "/" è la cartella dove LKL ha montato la partizione. Una partizione in sola lettura (supporto protetto)
 * risponde "permesso negato" a ogni scrittura. Un file scritto si chiude con fsync: finita la copia in
 * Esplora file, i dati sono già sul disco. */

enum {
    FXP_INIT = 1, FXP_VERSION, FXP_OPEN, FXP_CLOSE, FXP_READ, FXP_WRITE, FXP_LSTAT, FXP_FSTAT,
    FXP_SETSTAT, FXP_FSETSTAT, FXP_OPENDIR, FXP_READDIR, FXP_REMOVE, FXP_MKDIR, FXP_RMDIR,
    FXP_REALPATH, FXP_STAT, FXP_RENAME, FXP_READLINK, FXP_SYMLINK,
    FXP_STATUS = 101, FXP_HANDLE, FXP_DATA, FXP_NAME, FXP_ATTRS,
    FXP_EXTENDED = 200, FXP_EXTENDED_REPLY
};
enum { FX_OK, FX_EOF, FX_NO_SUCH_FILE, FX_PERMISSION_DENIED, FX_FAILURE, FX_BAD_MESSAGE,
       FX_NO_CONNECTION, FX_CONNECTION_LOST, FX_OP_UNSUPPORTED };
#define ATTR_SIZE 1
#define ATTR_UIDGID 2
#define ATTR_PERM 4
#define ATTR_TIME 8
#define FXF_READ 1
#define FXF_WRITE 2
#define FXF_APPEND 4
#define FXF_CREAT 8
#define FXF_TRUNC 0x10
#define FXF_EXCL 0x20

/* --- pacchetti --- */
struct buf { unsigned char *p; uint32_t len, cap, pos; };

static void b_need(struct buf *b, uint32_t n) {
    if (b->len + n <= b->cap) return;
    while (b->len + n > b->cap) b->cap = b->cap ? b->cap * 2 : 4096;
    b->p = realloc(b->p, b->cap);
}
static void put8(struct buf *b, uint8_t v) { b_need(b, 1); b->p[b->len++] = v; }
static void put32(struct buf *b, uint32_t v) { b_need(b, 4); for (int i = 3; i >= 0; i--) b->p[b->len++] = v >> (8 * i); }
static void put64(struct buf *b, uint64_t v) { put32(b, v >> 32); put32(b, (uint32_t)v); }
static void putn(struct buf *b, const void *s, uint32_t n) { put32(b, n); b_need(b, n); memcpy(b->p + b->len, s, n); b->len += n; }
static void puts_(struct buf *b, const char *s) { putn(b, s, strlen(s)); }
static int get32(struct buf *b, uint32_t *v) {
    if (b->pos + 4 > b->len) return -1;
    *v = (uint32_t)b->p[b->pos] << 24 | b->p[b->pos + 1] << 16 | b->p[b->pos + 2] << 8 | b->p[b->pos + 3];
    b->pos += 4; return 0;
}
static int get64(struct buf *b, uint64_t *v) { uint32_t h, l; if (get32(b, &h) || get32(b, &l)) return -1; *v = (uint64_t)h << 32 | l; return 0; }
static char *gets_(struct buf *b, uint32_t *n) {   /* stringa con lo zero finale (il pacchetto ha spazio) */
    uint32_t l; if (get32(b, &l) || b->pos + l > b->len) return NULL;
    char *s = malloc(l + 1); memcpy(s, b->p + b->pos, l); s[l] = 0; b->pos += l; if (n) *n = l; return s;
}

static int leggi_tutto(int fd, void *p, size_t n) {
    for (size_t f = 0; f < n;) { ssize_t r = read(fd, (char *)p + f, n - f); if (r <= 0) return -1; f += r; }
    return 0;
}
static int scrivi_tutto(int fd, const void *p, size_t n) {
    for (size_t f = 0; f < n;) { ssize_t r = write(fd, (const char *)p + f, n - f); if (r <= 0) return -1; f += r; }
    return 0;
}

/* --- una sessione --- */
#define MAX_HANDLE 256
struct handle { int usato, fd, dir, scritto; char percorso[1024]; };
struct sessione { int sock, ro; const char *radice; struct handle h[MAX_HANDLE]; struct buf out; };

static void inizia(struct sessione *s, uint8_t tipo, uint32_t id) {
    s->out.len = 0; put32(&s->out, 0); put8(&s->out, tipo); put32(&s->out, id);
}
static int invia(struct sessione *s) {
    uint32_t n = s->out.len - 4;
    for (int i = 0; i < 4; i++) s->out.p[i] = n >> (24 - 8 * i);
    return scrivi_tutto(s->sock, s->out.p, s->out.len);
}
/* l'errore preciso di Linux: in coda al messaggio, "(errno N)". Lo legge tod-fs.c (mkdir -p deve sapere
 * "esiste già", rm "cartella non vuota"...); gvfs mostra il messaggio così com'è */
static __thread long ultimo_errno;

static int stato(struct sessione *s, uint32_t id, uint32_t codice) {
    static const char *msg[] = {"Success", "End of file", "No such file", "Permission denied", "Failure",
                                "Bad message", "No connection", "Connection lost", "Operation unsupported"};
    char m[96];
    if (codice != FX_OK && codice != FX_EOF && ultimo_errno)
        snprintf(m, sizeof m, "%s (errno %ld)", lkl_strerror(-ultimo_errno), ultimo_errno);
    else
        snprintf(m, sizeof m, "%s", msg[codice <= 8 ? codice : 4]);
    ultimo_errno = 0;
    inizia(s, FXP_STATUS, id); put32(&s->out, codice); puts_(&s->out, m); puts_(&s->out, "");
    return invia(s);
}
static uint32_t da_errno(long e) {
    ultimo_errno = -e;
    if (e == -LKL_ENOENT || e == -LKL_ENOTDIR) return FX_NO_SUCH_FILE;
    if (e == -LKL_EACCES || e == -LKL_EPERM || e == -LKL_EROFS) return FX_PERMISSION_DENIED;
    return FX_FAILURE;
}

/* percorso del client → percorso in LKL, senza poter uscire dalla radice ("..") */
static void normalizza(const char *in, char *out, size_t n) {
    char tmp[1024], *parti[128], *sp;
    int k = 0;
    snprintf(tmp, sizeof tmp, "%s", in);
    for (char *t = strtok_r(tmp, "/", &sp); t && k < 128; t = strtok_r(NULL, "/", &sp)) {
        if (!strcmp(t, ".") || !*t) continue;
        if (!strcmp(t, "..")) { if (k) k--; continue; }
        parti[k++] = t;
    }
    size_t l = 0; out[0] = 0;
    for (int i = 0; i < k && l < n; i++) l += snprintf(out + l, n - l, "/%s", parti[i]);
    if (!k) snprintf(out, n, "/");
}
static void vero(struct sessione *s, const char *client, char *out, size_t n) {
    char norm[1024];
    normalizza(client, norm, sizeof norm);
    snprintf(out, n, "%s%s", s->radice, strcmp(norm, "/") ? norm : "");
}

static void attributi(struct buf *b, const struct lkl_stat *st) {
    put32(b, ATTR_SIZE | ATTR_UIDGID | ATTR_PERM | ATTR_TIME);
    put64(b, st->st_size);
    put32(b, getuid()); put32(b, getgid());   /* tutto dell'utente: Esplora file non segna "illeggibile" */
    put32(b, st->st_mode);
    put32(b, st->lkl_st_atime); put32(b, st->lkl_st_mtime);
}

struct attr { uint32_t flag, perm, atime, mtime; uint64_t size; };
static int get_attrs(struct buf *b, struct attr *a) {
    uint32_t x, n;
    memset(a, 0, sizeof *a);
    if (get32(b, &a->flag)) return -1;
    if (a->flag & ATTR_SIZE && get64(b, &a->size)) return -1;
    if (a->flag & ATTR_UIDGID && (get32(b, &x) || get32(b, &x))) return -1;
    if (a->flag & ATTR_PERM && get32(b, &a->perm)) return -1;
    if (a->flag & ATTR_TIME && (get32(b, &a->atime) || get32(b, &a->mtime))) return -1;
    if (a->flag & 0x80000000) {   /* estensioni: si saltano */
        if (get32(b, &n)) return -1;
        for (uint32_t i = 0; i < 2 * n; i++) { char *t = gets_(b, NULL); if (!t) return -1; free(t); }
    }
    return 0;
}

/* dimensione, permessi, orari (SETSTAT/FSETSTAT, e i permessi di OPEN/MKDIR). Proprietario: si ignora.
 * Su FAT/exFAT i permessi non esistono: il loro errore non fa fallire la copia */
static long applica_attrs(const char *p, int fd, const struct attr *a) {
    long r;
    if (a->flag & ATTR_SIZE) {
        r = fd >= 0 ? lkl_sys_ftruncate(fd, a->size) : lkl_sys_truncate(p, a->size);
        if (r) return r;
    }
    if (a->flag & ATTR_PERM) {
        r = fd >= 0 ? lkl_sys_fchmod(fd, a->perm & 07777) : lkl_sys_chmod(p, a->perm & 07777);
        if (r && r != -LKL_EPERM && r != -LKL_EOPNOTSUPP) return r;
    }
    if (a->flag & ATTR_TIME) {
        struct __lkl__kernel_timespec t[2] = {{a->atime, 0}, {a->mtime, 0}};
        r = fd >= 0 ? lkl_sys_utimensat(fd, NULL, t, 0) : lkl_sys_utimensat(LKL_AT_FDCWD, p, t, 0);
        if (r && r != -LKL_EPERM) return r;
    }
    return 0;
}

static int nuovo_handle(struct sessione *s, int fd, int dir, const char *p) {
    for (int i = 0; i < MAX_HANDLE; i++)
        if (!s->h[i].usato) { s->h[i] = (struct handle){1, fd, dir, 0, ""}; snprintf(s->h[i].percorso, sizeof s->h[i].percorso, "%s", p); return i; }
    return -1;
}
static struct handle *trova(struct sessione *s, struct buf *b) {
    uint32_t n; char *x = gets_(b, &n);
    if (!x) return NULL;
    int i = n == 4 ? (int)((uint32_t)(unsigned char)x[0] << 24 | (unsigned char)x[1] << 16 | (unsigned char)x[2] << 8 | (unsigned char)x[3]) : -1;
    free(x);
    return i >= 0 && i < MAX_HANDLE && s->h[i].usato ? &s->h[i] : NULL;
}
static void put_handle(struct buf *b, int i) { unsigned char x[4] = {i >> 24, i >> 16, i >> 8, i}; putn(b, x, 4); }

static void lunga(char *out, size_t n, const char *nome, const struct lkl_stat *st) {
    char perm[11] = "----------";
    unsigned m = st->st_mode;
    perm[0] = LKL_S_ISDIR(m) ? 'd' : LKL_S_ISLNK(m) ? 'l' : '-';
    for (int i = 0; i < 9; i++) if (m & (1 << (8 - i))) perm[1 + i] = "rwxrwxrwx"[i];
    char data[32]; time_t t = st->lkl_st_mtime; struct tm tm; localtime_r(&t, &tm);
    strftime(data, sizeof data, "%b %d %H:%M", &tm);
    snprintf(out, n, "%s 1 utente utente %lld %s %s", perm, (long long)st->st_size, data, nome);
}

/* quante modifiche sono passate da qui (tutte le sessioni, tutte le partizioni): tod-fs lo chiede ogni secondo
 * ("tod-cambi") e rilegge le cartelle che sorveglia solo se è cambiato, senza svegliare il disco */
static uint64_t cambi;

static int pacchetto(struct sessione *s, struct buf *in) {
    uint32_t len;
    unsigned char hdr[4];
    if (leggi_tutto(s->sock, hdr, 4)) return -1;
    len = (uint32_t)hdr[0] << 24 | hdr[1] << 16 | hdr[2] << 8 | hdr[3];
    if (len < 1 || len > 1 << 20) return -1;
    in->len = 0; in->pos = 0; b_need(in, len + 1);
    if (leggi_tutto(s->sock, in->p, len)) return -1;
    in->len = len;
    uint8_t tipo = in->p[in->pos++];
    uint32_t id = 0;
    if (tipo == FXP_INIT) {
        inizia(s, FXP_VERSION, 3);   /* VERSION non ha id: il 3 è la versione */
        puts_(&s->out, "statvfs@openssh.com"); puts_(&s->out, "2");
        puts_(&s->out, "posix-rename@openssh.com"); puts_(&s->out, "1");
        puts_(&s->out, "fsync@openssh.com"); puts_(&s->out, "1");
        return invia(s);
    }
    if (get32(in, &id)) return -1;
    char *a = NULL, p[1100];
    struct lkl_stat st;
    struct handle *h;
    long r;
    int esito = 0;
    switch (tipo) {
    case FXP_REALPATH: {
        if (!(a = gets_(in, NULL))) return -1;
        char norm[1024]; normalizza(a, norm, sizeof norm);
        inizia(s, FXP_NAME, id); put32(&s->out, 1); puts_(&s->out, norm); puts_(&s->out, norm); put32(&s->out, 0);
        esito = invia(s); break;
    }
    case FXP_STAT: case FXP_LSTAT:
        if (!(a = gets_(in, NULL))) return -1;
        vero(s, a, p, sizeof p);
        r = tipo == FXP_STAT ? lkl_sys_stat(p, &st) : lkl_sys_lstat(p, &st);
        if (r) { esito = stato(s, id, da_errno(r)); break; }
        inizia(s, FXP_ATTRS, id); attributi(&s->out, &st); esito = invia(s); break;
    case FXP_FSTAT:
        if (!(h = trova(s, in))) { esito = stato(s, id, FX_FAILURE); break; }
        if ((r = lkl_sys_fstat(h->fd, &st))) { esito = stato(s, id, da_errno(r)); break; }
        inizia(s, FXP_ATTRS, id); attributi(&s->out, &st); esito = invia(s); break;
    case FXP_OPENDIR:
        if (!(a = gets_(in, NULL))) return -1;
        vero(s, a, p, sizeof p);
        r = lkl_sys_open(p, LKL_O_RDONLY | LKL_O_DIRECTORY, 0);
        if (r < 0) { esito = stato(s, id, da_errno(r)); break; }
        { int i = nuovo_handle(s, r, 1, p);
          if (i < 0) { lkl_sys_close(r); esito = stato(s, id, FX_FAILURE); break; }
          inizia(s, FXP_HANDLE, id); put_handle(&s->out, i); esito = invia(s); }
        break;
    case FXP_READDIR: {
        if (!(h = trova(s, in)) || !h->dir) { esito = stato(s, id, FX_FAILURE); break; }
        char d[16384];
        r = lkl_sys_getdents64(h->fd, (struct lkl_linux_dirent64 *)d, sizeof d);
        if (r < 0) { esito = stato(s, id, da_errno(r)); break; }
        if (r == 0) { esito = stato(s, id, FX_EOF); break; }
        struct buf nomi = {0}; uint32_t quanti = 0;
        for (long o = 0; o < r;) {
            struct lkl_linux_dirent64 *de = (struct lkl_linux_dirent64 *)(d + o);
            o += de->d_reclen;
            char q[1400], lg[1600];
            snprintf(q, sizeof q, "%s/%s", h->percorso, de->d_name);
            if (lkl_sys_lstat(q, &st)) continue;
            lunga(lg, sizeof lg, de->d_name, &st);
            puts_(&nomi, de->d_name); puts_(&nomi, lg); attributi(&nomi, &st);
            quanti++;
        }
        inizia(s, FXP_NAME, id); put32(&s->out, quanti);
        b_need(&s->out, nomi.len); memcpy(s->out.p + s->out.len, nomi.p, nomi.len); s->out.len += nomi.len;
        free(nomi.p);
        esito = invia(s); break;
    }
    case FXP_OPEN: {
        uint32_t flag; struct attr at;
        if (!(a = gets_(in, NULL)) || get32(in, &flag) || get_attrs(in, &at)) return -1;
        int scrive = (flag & (FXF_WRITE | FXF_APPEND | FXF_CREAT | FXF_TRUNC)) != 0;
        if (scrive && s->ro) { esito = stato(s, id, FX_PERMISSION_DENIED); break; }
        int o = (flag & FXF_READ) && scrive ? LKL_O_RDWR : scrive ? LKL_O_WRONLY : LKL_O_RDONLY;
        if (flag & FXF_APPEND) o |= LKL_O_APPEND;
        if (flag & FXF_CREAT) o |= LKL_O_CREAT;
        if (flag & FXF_TRUNC) o |= LKL_O_TRUNC;
        if (flag & FXF_EXCL) o |= LKL_O_EXCL;
        vero(s, a, p, sizeof p);
        r = lkl_sys_open(p, o, at.flag & ATTR_PERM ? at.perm & 0777 : 0666);
        if (r < 0) { esito = stato(s, id, da_errno(r)); break; }
        int i = nuovo_handle(s, r, 0, p);
        if (i < 0) { lkl_sys_close(r); esito = stato(s, id, FX_FAILURE); break; }
        s->h[i].scritto = scrive;
        if (scrive) __atomic_add_fetch(&cambi, 1, __ATOMIC_RELAXED);
        inizia(s, FXP_HANDLE, id); put_handle(&s->out, i); esito = invia(s); break;
    }
    case FXP_WRITE: {
        uint64_t off; uint32_t n;
        if (!(h = trova(s, in)) || h->dir || get64(in, &off) || get32(in, &n) || in->pos + n > in->len) { esito = stato(s, id, FX_FAILURE); break; }
        r = lkl_sys_pwrite64(h->fd, (char *)in->p + in->pos, n, off);
        while (r > 0 && r < (long)n) {   /* scrittura a metà (disco quasi pieno): il resto, per avere l'errore vero */
            long k = lkl_sys_pwrite64(h->fd, (char *)in->p + in->pos + r, n - r, off + r);
            if (k <= 0) { r = k ? k : -LKL_ENOSPC; break; }
            r += k;
        }
        if (r != (long)n) fprintf(stderr, "sftp: scrittura di %u byte a %llu: %ld (%s)\n", n, (unsigned long long)off, r, r < 0 ? lkl_strerror(r) : "corta");
        h->scritto = 1;
        esito = stato(s, id, r == (long)n ? FX_OK : r < 0 ? da_errno(r) : FX_FAILURE); break;
    }
    case FXP_SETSTAT: case FXP_FSETSTAT: {
        struct attr at; int fd = -1;
        if (tipo == FXP_SETSTAT) { if (!(a = gets_(in, NULL))) return -1; vero(s, a, p, sizeof p); }
        else { if (!(h = trova(s, in))) { esito = stato(s, id, FX_FAILURE); break; } fd = h->fd; }
        if (get_attrs(in, &at)) return -1;
        if (s->ro) { esito = stato(s, id, FX_PERMISSION_DENIED); break; }
        r = applica_attrs(p, fd, &at);
        esito = stato(s, id, r ? da_errno(r) : FX_OK); break;
    }
    case FXP_REMOVE: case FXP_RMDIR:
        if (!(a = gets_(in, NULL))) return -1;
        if (s->ro) { esito = stato(s, id, FX_PERMISSION_DENIED); break; }
        vero(s, a, p, sizeof p);
        r = tipo == FXP_REMOVE ? lkl_sys_unlink(p) : lkl_sys_rmdir(p);
        esito = stato(s, id, r ? da_errno(r) : FX_OK); break;
    case FXP_MKDIR: {
        struct attr at;
        if (!(a = gets_(in, NULL)) || get_attrs(in, &at)) return -1;
        if (s->ro) { esito = stato(s, id, FX_PERMISSION_DENIED); break; }
        vero(s, a, p, sizeof p);
        r = lkl_sys_mkdir(p, at.flag & ATTR_PERM ? at.perm & 0777 : 0777);
        esito = stato(s, id, r ? da_errno(r) : FX_OK); break;
    }
    case FXP_RENAME: case FXP_SYMLINK: {   /* RENAME: senza sovrascrivere, come sftp-server */
        char *b2 = NULL, q[1100];
        if (!(a = gets_(in, NULL)) || !(b2 = gets_(in, NULL))) { free(b2); return -1; }
        if (s->ro) { free(b2); esito = stato(s, id, FX_PERMISSION_DENIED); break; }
        vero(s, b2, q, sizeof q);
        if (tipo == FXP_RENAME) { vero(s, a, p, sizeof p); r = lkl_sys_renameat2(LKL_AT_FDCWD, p, LKL_AT_FDCWD, q, LKL_RENAME_NOREPLACE);
            if (r == -LKL_EINVAL) { struct lkl_stat x; r = lkl_sys_lstat(q, &x) ? lkl_sys_rename(p, q) : -LKL_EEXIST; } }   /* FAT: niente NOREPLACE */
        else r = lkl_sys_symlink(a, q);   /* OpenSSH manda prima la destinazione, poi il collegamento */
        free(b2);
        esito = stato(s, id, r ? da_errno(r) : FX_OK); break;
    }
    case FXP_READ: {
        uint64_t off; uint32_t n;
        if (!(h = trova(s, in)) || get64(in, &off) || get32(in, &n)) { esito = stato(s, id, FX_FAILURE); break; }
        if (n > 255 * 1024) n = 255 * 1024;   /* come sftp-server: il pacchetto intero resta sotto 256 KB */
        inizia(s, FXP_DATA, id);
        uint32_t pos = s->out.len; put32(&s->out, 0); b_need(&s->out, n);
        r = lkl_sys_pread64(h->fd, (char *)s->out.p + s->out.len, n, off);
        if (r < 0) { esito = stato(s, id, da_errno(r)); break; }
        if (r == 0) { esito = stato(s, id, FX_EOF); break; }
        for (int i = 0; i < 4; i++) s->out.p[pos + i] = (uint32_t)r >> (24 - 8 * i);
        s->out.len += r;
        esito = invia(s); break;
    }
    case FXP_CLOSE:
        if (!(h = trova(s, in))) { esito = stato(s, id, FX_FAILURE); break; }
        r = h->scritto ? lkl_sys_fsync(h->fd) : 0;   /* copia finita = dati sul disco */
        if (h->scritto) __atomic_add_fetch(&cambi, 1, __ATOMIC_RELAXED);
        lkl_sys_close(h->fd); h->usato = 0;
        esito = stato(s, id, r ? da_errno(r) : FX_OK); break;
    case FXP_READLINK: {
        if (!(a = gets_(in, NULL))) return -1;
        vero(s, a, p, sizeof p);
        char dest[1024];
        r = lkl_sys_readlink(p, dest, sizeof dest - 1);
        if (r < 0) { esito = stato(s, id, da_errno(r)); break; }
        dest[r] = 0;
        inizia(s, FXP_NAME, id); put32(&s->out, 1); puts_(&s->out, dest); puts_(&s->out, dest); put32(&s->out, 0);
        esito = invia(s); break;
    }
    case FXP_EXTENDED: {
        char *nome = gets_(in, NULL);
        if (nome && !strcmp(nome, "statvfs@openssh.com") && (a = gets_(in, NULL))) {
            struct lkl_statfs sf;
            vero(s, a, p, sizeof p);
            if ((r = lkl_sys_statfs(p, &sf))) esito = stato(s, id, da_errno(r));
            else {
                inizia(s, FXP_EXTENDED_REPLY, id);
                put64(&s->out, sf.f_bsize); put64(&s->out, sf.f_frsize ? sf.f_frsize : sf.f_bsize);
                put64(&s->out, sf.f_blocks); put64(&s->out, sf.f_bfree); put64(&s->out, sf.f_bavail);
                put64(&s->out, sf.f_files); put64(&s->out, sf.f_ffree); put64(&s->out, sf.f_ffree);
                put64(&s->out, 0); put64(&s->out, s->ro ? 1 : 0 /* ST_RDONLY */); put64(&s->out, sf.f_namelen);
                esito = invia(s);
            }
        } else if (nome && !strcmp(nome, "posix-rename@openssh.com")) {   /* rinomina sovrascrivendo (gvfs) */
            char *b2 = NULL, q[1100];
            if (!(a = gets_(in, NULL)) || !(b2 = gets_(in, NULL))) { free(b2); free(nome); return -1; }
            vero(s, a, p, sizeof p); vero(s, b2, q, sizeof q); free(b2);
            r = s->ro ? -LKL_EROFS : lkl_sys_rename(p, q);
            __atomic_add_fetch(&cambi, 1, __ATOMIC_RELAXED);
            esito = stato(s, id, r ? da_errno(r) : FX_OK);
        } else if (nome && !strcmp(nome, "tod-cambi")) {
            inizia(s, FXP_EXTENDED_REPLY, id); put64(&s->out, __atomic_load_n(&cambi, __ATOMIC_RELAXED));
            esito = invia(s); free(nome); free(a); return esito;   /* chiedere non è una modifica */
        } else if (nome && !strcmp(nome, "fsync@openssh.com")) {
            if (!(h = trova(s, in))) esito = stato(s, id, FX_FAILURE);
            else { r = lkl_sys_fsync(h->fd); esito = stato(s, id, r ? da_errno(r) : FX_OK); }
        } else esito = stato(s, id, FX_OP_UNSUPPORTED);
        free(nome); break;
    }
    default:
        esito = stato(s, id, FX_OP_UNSUPPORTED);
    }
    free(a);
    switch (tipo) {
    case FXP_WRITE: case FXP_SETSTAT: case FXP_FSETSTAT: case FXP_REMOVE: case FXP_RMDIR:
    case FXP_MKDIR: case FXP_RENAME: case FXP_SYMLINK:
        __atomic_add_fetch(&cambi, 1, __ATOMIC_RELAXED);
    }
    return esito;
}

/* una sessione sftp sul socket già aperto, con radice RADICE (RO: sola lettura), fino alla chiusura. La prima riga
 * ("VOL <nome>", da tod-fs.so) l'ha già letta chi accetta la connessione. */
static void sftp_sessione(int sock, const char *radice, int ro) {
    struct sessione *s = calloc(1, sizeof *s);
    s->sock = sock;
    s->ro = ro;
    s->radice = radice;
    struct buf in = {0};
    while (pacchetto(s, &in) == 0) ;
    for (int i = 0; i < MAX_HANDLE; i++) if (s->h[i].usato) lkl_sys_close(s->h[i].fd);
    free(in.p); free(s->out.p); free(s);
}
