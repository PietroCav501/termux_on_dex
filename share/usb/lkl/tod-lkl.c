/* tod-lkl: un disco USB letto con il codice di Linux (LKL, Linux Kernel Library) direttamente in
 * Termux, senza root e senza emulazione.
 *
 *   termux-usb -r -e "tod-lkl RUN ID" /dev/bus/usb/...   un disco vero (termux-usb aggiunge il fd)
 *   tod-lkl --file IMMAGINE RUN ID                        un file immagine (prove senza chiavetta)
 *
 * Uno per disco, avviato da share/usb/tod-usb. Parla con la chiavetta o il lettore
 * di schede con i comandi SCSI della classe USB Mass Storage (Bulk-Only Transport), passa i settori a
 * LKL, monta ogni partizione e la offre ai programmi del desktop con un piccolo server sftp (sftp.c), uno
 * per partizione, su $RUN/lkl-<nome>.sock: tod-fs.so (LD_PRELOAD) ne fa le cartelle /media/usb/<nome>.
 *
 * Lettura e scrittura, come in una normale distribuzione; sola lettura solo se il supporto è protetto
 * (levetta della scheda). I dati scritti arrivano sul disco entro ~2 s (e alla chiusura di ogni file
 * scritto da Esplora file: fsync). Se il supporto cambia (scheda tolta o sostituita nel lettore) ogni
 * lettura e scrittura si ferma subito, senza aspettare il controllo periodico.
 *
 * File in RUN (= $TMPDIR/tod-usb):
 *   lkl-ID.pid       questo processo
 *   lkl-ID.volumi    una riga per partizione: nome, disco, tipo,
 *                    prodotto, byte, file system, etichetta, uuid (separati da TAB)
 *   lkl-ID.ctl       comandi: "espelli NOME" (smonta quella partizione: il disco resta ai comandi da
 *                    terminale finché non si scollega), "monta N" (rimonta la partizione N), "fine",
 *                    "pausa" (smonta tutto per un comando da terminale che cambia il disco: deve vedere
 *                    il disco smontato già quando lo legge, sennò ragiona su dati vecchi) e "riprendi"
 *                    (tabella riletta e partizioni rimontate)
 *   lkl-ID.parti     tutte le partizioni (anche quelle senza file system noto), per lsblk e blkid:
 *                    numero, inizio e byte, file system, etichetta, uuid, nome in Esplora file (o "-");
 *                    la riga 0 è il disco intero (byte, tipo di disco, prodotto, tabella: dos, gpt o vuoto,
 *                    1 se il supporto è protetto da scrittura)
 *   lkl-ID.spazio    per le partizioni montate: numero, byte usati, byte totali (Dischi; "aggiorna" lo rifà)
 *   lkl-ID.blk       il disco "grezzo" per i comandi da terminale (fdisk, mkfs, fsck: share/usb/lkl/
 *                    tod-disco.c). Chi lo apre per scrivere fa smontare tutte le partizioni; alla fine
 *                    la tabella delle partizioni si rilegge e si rimonta tutto
 *   lkl-ID.espulso   c'è finché tutte le partizioni sono espulse (il disco non si rimonta da solo)
 *   lkl-ID.riapri    scritto quando il supporto è cambiato (altra scheda nel lettore): si riapre
 *   lkl-ID.vuoto     c'è finché il lettore di schede è senza scheda
 * Uscita: 0 fermato, 3 disco scollegato, 4 supporto tolto o cambiato (scheda nel lettore). */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <libusb-1.0/libusb.h>
#include <lkl.h>
#include <lkl_host.h>

#define LKL_MS_RDONLY 1

#include "sftp.c"

static const char *RUN, *ID;
static volatile sig_atomic_t fermati;

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    char t[32]; time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm);
    strftime(t, sizeof t, "%F %T", &tm);
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "%s lkl %s: ", t, ID ? ID : "?");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static void percorso(char *out, size_t n, const char *fmt, const char *x) {
    char nome[300]; snprintf(nome, sizeof nome, fmt, x);
    snprintf(out, n, "%s/%s", RUN, nome);
}

/* ---------- la chiavetta: USB Mass Storage, Bulk-Only Transport, comandi SCSI ---------- */

static libusb_device_handle *usb;
static unsigned char ep_in, ep_out;
static int usb_iface, usb_sparito, protetto;
static volatile int armato, cambiato;   /* dopo il montaggio: un "supporto cambiato" ferma tutto */
static uint32_t tag = 1, blocco = 512;
static uint64_t blocchi;
static pthread_mutex_t usb_lock = PTHREAD_MUTEX_INITIALIZER;
static char prodotto[128], marca_modello[64];
static uint16_t vid, pid;

static int bulk(unsigned char ep, void *buf, int len, int *fatti) {
    int r = libusb_bulk_transfer(usb, ep, buf, len, fatti, 5000);
    if (r == LIBUSB_ERROR_PIPE) { libusb_clear_halt(usb, ep); r = libusb_bulk_transfer(usb, ep, buf, len, fatti, 5000); }
    if (r == LIBUSB_ERROR_NO_DEVICE) usb_sparito = 1;
    return r;
}

/* un comando SCSI: CBW (31 byte), dati (verso di noi o, con FUORI, verso il disco), CSW (13 byte).
 * Esito SCSI (0 = riuscito) o <0 */
static int scsi_dir(const unsigned char *cdb, int cdblen, void *dati, uint32_t len, int fuori) {
    unsigned char cbw[31] = {0}, csw[13];
    int n, r;
    memcpy(cbw, "USBC", 4);
    memcpy(cbw + 4, &tag, 4);
    memcpy(cbw + 8, &len, 4);
    cbw[12] = fuori ? 0x00 : 0x80;
    cbw[14] = cdblen;
    memcpy(cbw + 15, cdb, cdblen);
    if ((r = bulk(ep_out, cbw, 31, &n)) || n != 31) return -1;
    if (len && fuori) {
        r = bulk(ep_out, dati, len, &n);
        if (r && r != LIBUSB_ERROR_PIPE) return -2;
    } else if (len) {
        r = bulk(ep_in, dati, len, &n);
        if (r && r != LIBUSB_ERROR_PIPE) return -2;
        if (n == 13 && len != 13 && !memcmp(dati, "USBS", 4)) {   /* niente dati: è già la risposta finale */
            memcpy(csw, dati, 13);
            goto stato;
        }
    }
    if ((r = bulk(ep_in, csw, 13, &n)) || n != 13 || memcmp(csw, "USBS", 4)) return -3;
stato:
    tag++;
    return csw[12];
}

static int scsi(const unsigned char *cdb, int cdblen, void *dati, uint32_t len) { return scsi_dir(cdb, cdblen, dati, len, 0); }

static void ripristina(void) {   /* Bulk-Only Mass Storage Reset e sblocco degli endpoint (BOT 5.3.4) */
    libusb_control_transfer(usb, 0x21, 0xff, 0, usb_iface, NULL, 0, 2000);
    libusb_clear_halt(usb, ep_in);
    libusb_clear_halt(usb, ep_out);
}

static int senso(unsigned char *k, unsigned char *asc) {   /* REQUEST SENSE: chiave e codice */
    unsigned char s[18] = {0}, c[6] = {0x03, 0, 0, 0, 18, 0};
    int r = scsi(c, 6, s, 18);
    *k = s[2] & 0xf; *asc = s[12];
    return r;
}

/* con nuovi tentativi: le chiavette rifiutano ogni tanto un comando (errore del supporto) e poi lo fanno.
 * Ma un supporto tolto o cambiato (UNIT ATTENTION 28, MEDIUM NOT PRESENT 3A) dopo il montaggio non si
 * riprova: da lì niente più letture né scritture (incidente del 16 ottobre, quando i dischi li leggeva una macchina QEMU) */
static int scsi_rd(const unsigned char *cdb, int cdblen, void *dati, uint32_t len, int fuori) {
    if (cambiato) return -9;
    int e = scsi_dir(cdb, cdblen, dati, len, fuori);
    for (int i = 0; e != 0 && i < 4 && !usb_sparito; i++) {
        if (e < 0) ripristina();
        else {
            unsigned char k, a;
            senso(&k, &a);
            if (armato && ((k == 6 && a == 0x28) || (k == 2 && a == 0x3a))) { cambiato = 1; return -9; }
            if (k == 7) return e;   /* protetto da scrittura: inutile riprovare */
            usleep(100000);
        }
        e = scsi_dir(cdb, cdblen, dati, len, fuori);
    }
    return e;
}
static int scsi_r(const unsigned char *cdb, int cdblen, void *dati, uint32_t len) { return scsi_rd(cdb, cdblen, dati, len, 0); }

static int capacita(void) {
    unsigned char cap[32], c[10] = {0x25};
    if (scsi_r(c, 10, cap, 8)) return -1;
    uint32_t last = (uint32_t)cap[0] << 24 | cap[1] << 16 | cap[2] << 8 | cap[3];
    blocco = (uint32_t)cap[4] << 24 | cap[5] << 16 | cap[6] << 8 | cap[7];
    blocchi = (uint64_t)last + 1;
    if (last == 0xffffffff) {   /* oltre 2 TB */
        unsigned char c16[16] = {0x9e, 0x10};
        c16[13] = 32;
        if (scsi_r(c16, 16, cap, 32)) return -1;
        uint64_t l = 0;
        for (int i = 0; i < 8; i++) l = l << 8 | cap[i];
        blocchi = l + 1;
        blocco = (uint32_t)cap[8] << 24 | cap[9] << 16 | cap[10] << 8 | cap[11];
    }
    if (blocco < 512 || blocco > 4096 || (blocco & (blocco - 1))) return -1;
    return 0;
}

/* il supporto c'è? 0 pronto, 1 non c'è (lettore vuoto), 2 cambiato, -1 disco sparito */
static int pronto(void) {
    unsigned char c[6] = {0}, k, a;
    int r = scsi(c, 6, NULL, 0);
    if (usb_sparito) return -1;
    if (r < 0) { ripristina(); return usb_sparito ? -1 : 1; }
    if (r == 0) return 0;
    senso(&k, &a);
    if (usb_sparito) return -1;
    if (k == 6 && a == 0x28) return 2;   /* UNIT ATTENTION: supporto cambiato */
    return 1;
}

static int usb_apri(int fd) {
    libusb_context *ctx;
    struct libusb_config_descriptor *cfg;
    struct libusb_device_descriptor dd;
    libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY);
    if (libusb_init(&ctx)) return -1;
    if (libusb_wrap_sys_device(ctx, (intptr_t)fd, &usb)) return -2;
    if (!libusb_get_device_descriptor(libusb_get_device(usb), &dd)) {
        vid = dd.idVendor; pid = dd.idProduct;
        if (dd.iProduct) libusb_get_string_descriptor_ascii(usb, dd.iProduct, (unsigned char *)prodotto, sizeof prodotto);
    }
    if (libusb_get_active_config_descriptor(libusb_get_device(usb), &cfg)) return -3;
    int iface = -1;
    for (int i = 0; i < cfg->bNumInterfaces && iface < 0; i++) {
        const struct libusb_interface_descriptor *d = &cfg->interface[i].altsetting[0];
        if (d->bInterfaceClass != 8 || d->bInterfaceProtocol != 0x50) continue;   /* mass storage, bulk-only */
        for (int e = 0; e < d->bNumEndpoints; e++) {
            const struct libusb_endpoint_descriptor *ep = &d->endpoint[e];
            if ((ep->bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_BULK) continue;
            if (ep->bEndpointAddress & 0x80) ep_in = ep->bEndpointAddress; else ep_out = ep->bEndpointAddress;
        }
        iface = usb_iface = d->bInterfaceNumber;
    }
    libusb_free_config_descriptor(cfg);
    if (iface < 0 || !ep_in || !ep_out) return -4;
    libusb_set_auto_detach_kernel_driver(usb, 1);
    if (libusb_claim_interface(usb, iface)) return -5;
    unsigned char inq[36] = {0}, c[6] = {0x12, 0, 0, 0, 36, 0};
    if (scsi_r(c, 6, inq, 36) < 0) return -6;
    snprintf(marca_modello, sizeof marca_modello, "%.8s %.16s", inq + 8, inq + 16);
    return 0;
}

static int legge_protezione(void) {   /* MODE SENSE (6): bit WP dell'intestazione = levetta su "protetto" */
    unsigned char ms[4] = {0}, c[6] = {0x1a, 0, 0x3f, 0, 4, 0};
    if (scsi_r(c, 6, ms, 4)) return 0;   /* chi non risponde si tratta come scrivibile */
    return (ms[2] & 0x80) != 0;
}

#define MAX_TRASF (120 * 1024)   /* come Linux (max_sectors 240): richieste più grandi, qualche chiavetta le rifiuta */

/* lettura anticipata: LKL legge le cartelle FAT un settore da 512 byte alla volta, e ogni comando SCSI
 * costa ~2 ms qualunque sia la sua dimensione (4 novembre: prima apertura della Scheda SD, 4277 letture
 * da 512 byte in fila, 10 s). Quando una lettura prosegue la precedente si leggono ANTICIPO byte in un
 * colpo e le successive escono da qui. TOD_LKL_ANTICIPO=0 la spegne */
#define ANTICIPO (64 * 1024)
static int senza_anticipo;
static unsigned char *ant;
static uint64_t ant_ini, ant_len, ult_fine = UINT64_MAX;
static unsigned comandi;   /* comandi di lettura e scrittura mandati al disco (per la traccia) */

static void anticipo_butta(uint64_t off, uint64_t len) {   /* una scrittura che tocca la finestra */
    if (ant_len && off < ant_ini + ant_len && ant_ini < off + len) ant_len = 0;
}

static int usb_io(uint64_t off, unsigned char *buf, uint64_t len, int scrivi) {
    if (scrivi) anticipo_butta(off, len);
    while (len) {
        comandi++;
        uint32_t n = len > MAX_TRASF ? MAX_TRASF : (uint32_t)len, nb = n / blocco;
        uint64_t lba = off / blocco;
        unsigned char c[16] = {0};
        int cl;
        if (lba > 0xffffffffULL) {
            c[0] = scrivi ? 0x8a : 0x88; for (int i = 0; i < 8; i++) c[2 + i] = lba >> (56 - 8 * i);
            c[10] = nb >> 24; c[11] = nb >> 16; c[12] = nb >> 8; c[13] = nb; cl = 16;
        } else {
            c[0] = scrivi ? 0x2a : 0x28; c[2] = lba >> 24; c[3] = lba >> 16; c[4] = lba >> 8; c[5] = lba; c[7] = nb >> 8; c[8] = nb; cl = 10;
        }
        int e = scsi_rd(c, cl, buf, n, scrivi);
        if (e) {
            if (e != -9) logf_("%s fallita al settore %llu", scrivi ? "scrittura" : "lettura", (unsigned long long)lba);
            return -1;
        }
        buf += n; off += n; len -= n;
    }
    return 0;
}

static int usb_leggi(uint64_t off, unsigned char *buf, uint64_t len) {
    if (ant_len && off >= ant_ini && off + len <= ant_ini + ant_len) {
        memcpy(buf, ant + (off - ant_ini), len);
        ult_fine = off + len;
        return 0;
    }
    int segue = off == ult_fine;
    ult_fine = off + len;
    uint64_t n = off < blocchi * blocco ? blocchi * blocco - off : 0;   /* mai oltre la fine del disco */
    if (n > ANTICIPO) n = ANTICIPO;
    if (segue && len < n && !senza_anticipo && (ant || (ant = malloc(ANTICIPO)))) {
        ant_len = 0;
        if (!usb_io(off, ant, n, 0)) {
            ant_ini = off; ant_len = n;
            memcpy(buf, ant, len);
            return 0;
        }   /* un settore illeggibile oltre quelli chiesti non deve far fallire la lettura */
    }
    return usb_io(off, buf, len, 0);
}

static int usb_capacita_op(struct lkl_disk d, unsigned long long *res) { (void)d; *res = blocchi * blocco; return 0; }

/* diagnosi: se nella cartella di lavoro c'è il file "traccia", ogni richiesta del kernel finisce in
 * traccia-ID.txt (ms dall'avvio, tipo, settore, byte, durata in ms, comandi mandati al disco: 0 = dalla
 * lettura anticipata) */
static FILE *traccia;
static double ms_ora(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static double ms_avvio;

static int usb_richiesta_vera(struct lkl_disk d, struct lkl_blk_req *req);
static int usb_richiesta(struct lkl_disk d, struct lkl_blk_req *req) {
    if (!traccia) return usb_richiesta_vera(d, req);
    double t = ms_ora();
    unsigned c = comandi;
    uint64_t tot = 0;
    for (int i = 0; i < req->count; i++) tot += req->buf[i].iov_len;
    int r = usb_richiesta_vera(d, req);
    fprintf(traccia, "%.1f %c %llu %llu %.1f %u\n", t - ms_avvio, req->type == LKL_DEV_BLK_TYPE_READ ? 'R' : req->type == LKL_DEV_BLK_TYPE_WRITE ? 'W' : 'F',
            (unsigned long long)req->sector, (unsigned long long)tot, ms_ora() - t, comandi - c);
    fflush(traccia);
    return r;
}

static int usb_richiesta_vera(struct lkl_disk d, struct lkl_blk_req *req) {
    (void)d;
    if (req->type == LKL_DEV_BLK_TYPE_FLUSH || req->type == LKL_DEV_BLK_TYPE_FLUSH_OUT) {
        unsigned char c[10] = {0x35};   /* SYNCHRONIZE CACHE: chi non lo conosce non ha cache da svuotare */
        pthread_mutex_lock(&usb_lock);
        int r = cambiato || usb_sparito ? -1 : 0;
        if (!r) scsi(c, 10, NULL, 0);
        pthread_mutex_unlock(&usb_lock);
        return r ? LKL_DEV_BLK_STATUS_IOERR : LKL_DEV_BLK_STATUS_OK;
    }
    int scrivi = req->type == LKL_DEV_BLK_TYPE_WRITE;
    if (req->type != LKL_DEV_BLK_TYPE_READ && !scrivi) return LKL_DEV_BLK_STATUS_UNSUP;
    if (scrivi && protetto) return LKL_DEV_BLK_STATUS_IOERR;
    uint64_t tot = 0;
    for (int i = 0; i < req->count; i++) tot += req->buf[i].iov_len;
    uint64_t off = req->sector * 512, ini = off / blocco * blocco, fine = (off + tot + blocco - 1) / blocco * blocco;
    static unsigned char *tmp; static uint64_t tmplen;
    pthread_mutex_lock(&usb_lock);
    if (fine - ini > tmplen) { free(tmp); tmplen = fine - ini; tmp = malloc(tmplen); }
    int r = usb_sparito || cambiato || !tmp ? -1 : 0;
    if (!r && scrivi) {
        /* settori del disco più grandi di 512 byte (4 KB): i bordi si leggono e si riscrivono interi */
        if (off != ini) r = usb_leggi(ini, tmp, blocco);
        if (!r && off + tot != fine && (fine - blocco > ini || off == ini)) r = usb_leggi(fine - blocco, tmp + (fine - ini) - blocco, blocco);
        unsigned char *p = tmp + (off - ini);
        for (int i = 0; !r && i < req->count; i++) { memcpy(p, req->buf[i].iov_base, req->buf[i].iov_len); p += req->buf[i].iov_len; }
        if (!r) r = usb_io(ini, tmp, fine - ini, 1);
    } else if (!r) {
        r = usb_leggi(ini, tmp, fine - ini);
        unsigned char *p = tmp + (off - ini);
        for (int i = 0; !r && i < req->count; i++) { memcpy(req->buf[i].iov_base, p, req->buf[i].iov_len); p += req->buf[i].iov_len; }
    }
    pthread_mutex_unlock(&usb_lock);
    return r ? LKL_DEV_BLK_STATUS_IOERR : LKL_DEV_BLK_STATUS_OK;
}

static struct lkl_dev_blk_ops usb_ops = { .get_capacity = usb_capacita_op, .request = usb_richiesta };

/* ---------- "Scheda SD" o "Chiavetta USB" ---------- */

static const char *tipo_disco(void) {
    char s[256];
    snprintf(s, sizeof s, "%s %s", prodotto, marca_modello);
    if (strcasestr(s, "card") || strcasestr(s, "reader") || strstr(s, "SD") || strstr(s, "MMC") || strstr(s, "STORAGE DEVICE"))
        return "Scheda SD";
    if ((vid == 0x05e3 && (pid >> 8) == 0x07) || (vid == 0x0bda && (pid >> 8) == 0x01) || (vid == 0x058f && (pid >> 8) == 0x63) ||
        vid == 0x14cd || (vid == 0x8564 && pid == 0x4000) || vid == 0x0dda || vid == 0x1e3d)
        return "Scheda SD";
    return "Chiavetta USB";
}

/* ---------- riconoscere il file system: tipo, etichetta, uuid (come blkid) ---------- */

struct fs { char tipo[16], driver[16], etichetta[256], uuid[64]; };

static int rd(int fd, uint64_t off, void *b, size_t n) { return lkl_sys_pread64(fd, b, n, off) == (long)n ? 0 : -1; }
static uint16_t u16(const unsigned char *p) { return p[0] | p[1] << 8; }
static uint32_t u32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t u64(const unsigned char *p) { return u32(p) | (uint64_t)u32(p + 4) << 32; }

static void utf16(char *out, size_t n, const unsigned char *p, int car) {   /* UTF-16LE → UTF-8 */
    size_t k = 0;
    for (int i = 0; i < car && k + 4 < n; i++) {
        unsigned c = u16(p + 2 * i);
        if (!c) break;
        if (c < 0x80) out[k++] = c;
        else if (c < 0x800) { out[k++] = 0xc0 | c >> 6; out[k++] = 0x80 | (c & 0x3f); }
        else { out[k++] = 0xe0 | c >> 12; out[k++] = 0x80 | ((c >> 6) & 0x3f); out[k++] = 0x80 | (c & 0x3f); }
    }
    out[k] = 0;
}

/* le etichette FAT sono nella codifica DOS di Windows (pagina 850 per l'Europa occidentale: "UNITÀ USB"
 * di Windows in italiano ha 0xB7 per À): in UTF-8 */
static const unsigned short CP850[128] = {
    0xC7, 0xFC, 0xE9, 0xE2, 0xE4, 0xE0, 0xE5, 0xE7, 0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xEC, 0xC4, 0xC5,
    0xC9, 0xE6, 0xC6, 0xF4, 0xF6, 0xF2, 0xFB, 0xF9, 0xFF, 0xD6, 0xDC, 0xF8, 0xA3, 0xD8, 0xD7, 0x192,
    0xE1, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xAA, 0xBA, 0xBF, 0xAE, 0xAC, 0xBD, 0xBC, 0xA1, 0xAB, 0xBB,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0xC1, 0xC2, 0xC0, 0xA9, 0x2563, 0x2551, 0x2557, 0x255D, 0xA2, 0xA5, 0x2510,
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0xE3, 0xC3, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0xA4,
    0xF0, 0xD0, 0xCA, 0xCB, 0xC8, 0x131, 0xCD, 0xCE, 0xCF, 0x2518, 0x250C, 0x2588, 0x2584, 0xA6, 0xCC, 0x2580,
    0xD3, 0xDF, 0xD4, 0xD2, 0xF5, 0xD5, 0xB5, 0xFE, 0xDE, 0xDA, 0xDB, 0xD9, 0xFD, 0xDD, 0xAF, 0xB4,
    0xAD, 0xB1, 0x2017, 0xBE, 0xB6, 0xA7, 0xF7, 0xB8, 0xB0, 0xA8, 0xB7, 0xB9, 0xB3, 0xB2, 0x25A0, 0xA0};

static void da_dos(char *out, size_t n, const unsigned char *in, size_t l) {
    size_t k = 0;
    for (size_t i = 0; i < l && in[i] && k + 4 < n; i++) {
        unsigned c = in[i] < 0x80 ? in[i] : CP850[in[i] - 0x80];
        if (c < 0x80) out[k++] = c;
        else if (c < 0x800) { out[k++] = 0xc0 | c >> 6; out[k++] = 0x80 | (c & 0x3f); }
        else { out[k++] = 0xe0 | c >> 12; out[k++] = 0x80 | ((c >> 6) & 0x3f); out[k++] = 0x80 | (c & 0x3f); }
    }
    out[k] = 0;
}

static void spazi_via(char *s) { size_t l = strlen(s); while (l && (s[l - 1] == ' ' || s[l - 1] == 0)) s[--l] = 0; }

static void uuid_lungo(char *out, size_t n, const unsigned char *u) {
    snprintf(out, n, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}

static int prova_fs(int fd, struct fs *f) {
    unsigned char b[4096];
    memset(f, 0, sizeof *f);
    if (rd(fd, 0, b, sizeof b)) return -1;
    if (!memcmp(b + 3, "EXFAT   ", 8)) {
        strcpy(f->tipo, "exfat"); strcpy(f->driver, "exfat");
        uint32_t s = u32(b + 100);
        snprintf(f->uuid, sizeof f->uuid, "%04X-%04X", s >> 16, s & 0xffff);
        uint32_t bps = 1u << b[108], cl = bps << b[109];
        uint64_t root = (uint64_t)u32(b + 88) * bps + (uint64_t)(u32(b + 96) - 2) * cl;
        unsigned char *d = malloc(cl > 65536 ? 65536 : cl);
        size_t dl = cl > 65536 ? 65536 : cl;
        if (d && !rd(fd, root, d, dl))
            for (size_t o = 0; o + 32 <= dl && d[o]; o += 32)
                if (d[o] == 0x83) { utf16(f->etichetta, sizeof f->etichetta, d + o + 2, d[o + 1] > 11 ? 11 : d[o + 1]); break; }
        free(d);
        return 0;
    }
    if (!memcmp(b + 3, "NTFS    ", 8)) {
        strcpy(f->tipo, "ntfs"); strcpy(f->driver, "ntfs3");
        snprintf(f->uuid, sizeof f->uuid, "%016llX", (unsigned long long)u64(b + 72));
        uint32_t bps = u16(b + 11), cl = bps * b[13];
        int8_t r = (int8_t)b[64];
        uint32_t rec = r < 0 ? 1u << -r : r * cl;
        if (rec >= 1024 && rec <= 65536) {   /* il nome del volume: record 3 della MFT ($Volume), attributo 0x60 */
            unsigned char *m = malloc(rec);
            if (m && !rd(fd, u64(b + 48) * cl + 3 * (uint64_t)rec, m, rec) && !memcmp(m, "FILE", 4)) {
                uint16_t uso = u16(m + 4), nuso = u16(m + 6);   /* correzioni di fine settore */
                for (int i = 1; i < nuso && i * 512 <= (int)rec && uso + 2 * i + 1 < (int)rec; i++) memcpy(m + i * 512 - 2, m + uso + 2 * i, 2);
                for (uint32_t a = u16(m + 20); a + 24 <= rec;) {
                    uint32_t t = u32(m + a), l = u32(m + a + 4);
                    if (t == 0xffffffff || l < 16 || a + l > rec) break;
                    if (t == 0x60 && !m[a + 8]) { utf16(f->etichetta, sizeof f->etichetta, m + a + u16(m + a + 20), u32(m + a + 16) / 2); break; }
                    a += l;
                }
            }
            free(m);
        }
        return 0;
    }
    if (b[510] == 0x55 && b[511] == 0xaa && (!memcmp(b + 82, "FAT32", 5) || !memcmp(b + 54, "FAT", 3))) {
        strcpy(f->tipo, "vfat"); strcpy(f->driver, "vfat");
        int f32 = u16(b + 22) == 0;
        uint32_t s = u32(b + (f32 ? 67 : 39));
        snprintf(f->uuid, sizeof f->uuid, "%04X-%04X", s >> 16, s & 0xffff);
        uint32_t bps = u16(b + 11), spc = b[13], res = u16(b + 14), nf = b[16];
        uint64_t off; size_t dl;
        if (f32) { off = (uint64_t)(res + nf * u32(b + 36)) * bps + (uint64_t)(u32(b + 44) - 2) * spc * bps; dl = spc * bps; }
        else { off = (uint64_t)(res + nf * u16(b + 22)) * bps; dl = u16(b + 17) * 32; }
        if (dl > 65536) dl = 65536;
        unsigned char *d = malloc(dl ? dl : 1);
        if (d && dl && !rd(fd, off, d, dl))   /* il nome vero sta nella cartella principale (voce "etichetta") */
            for (size_t o = 0; o + 32 <= dl && d[o]; o += 32)
                if (d[o] != 0xe5 && d[o + 11] == 0x08) { da_dos(f->etichetta, sizeof f->etichetta, d + o, 11); break; }
        free(d);
        if (!*f->etichetta) {
            da_dos(f->etichetta, sizeof f->etichetta, b + (f32 ? 71 : 43), 11);
            if (!strncmp(f->etichetta, "NO NAME", 7)) *f->etichetta = 0;
        }
        spazi_via(f->etichetta);
        return 0;
    }
    if (u16(b + 1080) == 0xef53) {
        uint32_t compat = u32(b + 1116), incompat = u32(b + 1120);
        strcpy(f->tipo, incompat & 0x2c0 ? "ext4" : compat & 4 ? "ext3" : "ext2");
        strcpy(f->driver, "ext4");
        snprintf(f->etichetta, 17, "%.16s", b + 1144);
        uuid_lungo(f->uuid, sizeof f->uuid, b + 1128);
        return 0;
    }
    if (!memcmp(b, "XFSB", 4)) {
        strcpy(f->tipo, "xfs"); strcpy(f->driver, "xfs");
        snprintf(f->etichetta, 13, "%.12s", b + 108);
        uuid_lungo(f->uuid, sizeof f->uuid, b + 32);
        return 0;
    }
    if (!rd(fd, 0x10000, b, sizeof b) && !memcmp(b + 0x40, "_BHRfS_M", 8)) {
        strcpy(f->tipo, "btrfs"); strcpy(f->driver, "btrfs");
        snprintf(f->etichetta, sizeof f->etichetta, "%.255s", b + 0x12b);
        uuid_lungo(f->uuid, sizeof f->uuid, b + 0x20);
        return 0;
    }
    return -1;
}

/* ---------- le partizioni ---------- */

#define MAXCLIENT 512   /* connessioni per partizione: ogni programma con tod-fs ne apre fino a 4 */
struct volume {
    int part, montato, ro, ascolto, client[MAXCLIENT];
    char nome[256], alias[256], dove[256], sock[512];
    struct fs fs;
    uint64_t byte;
};
static struct volume vol[64];
static int nvol, disk_id;
struct parte { int n; uint64_t inizio, byte; struct fs fs; };
static struct parte parti[65];
static int nparti;

static long leggi_numero(const char *p) {   /* un numero da un file di sysfs (in LKL) */
    char b[32] = ""; int f = lkl_sys_open(p, LKL_O_RDONLY, 0);
    if (f < 0) return -1;
    long n = lkl_sys_read(f, b, sizeof b - 1); lkl_sys_close(f);
    return n > 0 ? atol(b) : -1;
}

static const char *tabella(void) {   /* GPT ("EFI PART" nel settore 1) o MBR (0x55AA nel settore 0) */
    static char t[8];
    uint32_t dev;
    t[0] = 0;
    if (lkl_get_virtio_blkdev(disk_id, 0, &dev)) return t;
    lkl_sys_mknod("/dev/tab", LKL_S_IFBLK | 0600, dev);
    int f = lkl_sys_open("/dev/tab", LKL_O_RDONLY, 0);
    unsigned char b[1024];
    if (f >= 0 && lkl_sys_pread64(f, (char *)b, 1024, 0) == 1024)
        snprintf(t, sizeof t, "%s", !memcmp(b + 512, "EFI PART", 8) ? "gpt" : b[510] == 0x55 && b[511] == 0xaa ? "dos" : "");
    if (f >= 0) lkl_sys_close(f);
    lkl_sys_unlink("/dev/tab");
    return t;
}

/* Lo spazio si calcola in un thread a parte: la prima volta FAT e exFAT contano i blocchi liberi leggendo
 * tutta la mappa (su un disco grande, secondi), e il ciclo principale, che accetta le connessioni, non deve
 * aspettare. spazio_lock lo tiene chi calcola; smonta() lo prende prima di smontare. */
static pthread_mutex_t spazio_lock = PTHREAD_MUTEX_INITIALIZER, spazio_stato = PTHREAD_MUTEX_INITIALIZER;
static int spazio_da_fare, spazio_in_corso;
static void scrivi_spazio_ora(void);
static void *spazio_thread(void *x) {
    (void)x;
    for (;;) {
        pthread_mutex_lock(&spazio_stato);
        if (!spazio_da_fare) { spazio_in_corso = 0; pthread_mutex_unlock(&spazio_stato); return NULL; }
        spazio_da_fare = 0;
        pthread_mutex_unlock(&spazio_stato);
        pthread_mutex_lock(&spazio_lock); scrivi_spazio_ora(); pthread_mutex_unlock(&spazio_lock);
    }
}
static void scrivi_spazio(void) {
    pthread_mutex_lock(&spazio_stato);
    spazio_da_fare = 1;
    if (!spazio_in_corso) {
        pthread_t t;
        spazio_in_corso = pthread_create(&t, NULL, spazio_thread, NULL) == 0;
        if (spazio_in_corso) pthread_detach(t);
    }
    int subito = !spazio_in_corso;
    pthread_mutex_unlock(&spazio_stato);
    if (subito) { pthread_mutex_lock(&spazio_lock); scrivi_spazio_ora(); pthread_mutex_unlock(&spazio_lock); }
}
static void scrivi_spazio_ora(void) {
    char p[512], t[520];
    percorso(p, sizeof p, "lkl-%s.spazio", ID);
    snprintf(t, sizeof t, "%s.tmp", p);
    FILE *f = fopen(t, "w");
    if (!f) return;
    for (int i = 0; i < nvol; i++) {
        struct lkl_statfs sf;
        if (!vol[i].montato || lkl_sys_statfs(vol[i].dove, &sf)) continue;
        unsigned long long bs = sf.f_frsize ? sf.f_frsize : sf.f_bsize;
        fprintf(f, "%d\t%llu\t%llu\n", vol[i].part, (unsigned long long)(sf.f_blocks - sf.f_bfree) * bs, (unsigned long long)sf.f_blocks * bs);
    }
    fclose(f);
    rename(t, p);
}

static void scrivi_parti(void) {
    char p[512], t[520];
    percorso(p, sizeof p, "lkl-%s.parti", ID);
    snprintf(t, sizeof t, "%s.tmp", p);
    FILE *f = fopen(t, "w");
    if (!f) return;
    fprintf(f, "0\t0\t%llu\t%s\t%s\t%s\t%d\n", (unsigned long long)(blocchi * blocco), tipo_disco(), *prodotto ? prodotto : marca_modello, tabella(), protetto);
    for (int i = 0; i < nparti; i++) {
        const char *nome = "-";
        for (int j = 0; j < nvol; j++) if (vol[j].montato && vol[j].part == parti[i].n) nome = vol[j].nome;
        if (parti[i].n == 0) continue;
        fprintf(f, "%d\t%llu\t%llu\t%s\t%s\t%s\t%s\n", parti[i].n, (unsigned long long)parti[i].inizio, (unsigned long long)parti[i].byte,
                parti[i].fs.tipo, parti[i].fs.etichetta, parti[i].fs.uuid, nome);
    }
    fclose(f);
    rename(t, p);
}
static pthread_mutex_t vol_lock = PTHREAD_MUTEX_INITIALIZER;

static void alias_di(const char *nome, char *out, size_t n) {   /* come alias_of in tod-usb: gvfs vuole minuscole */
    size_t i = 0;
    for (; nome[i] && i + 1 < n; i++) {
        char c = nome[i];
        out[i] = c == ' ' ? '-' : c == '/' ? '_' : (c >= 'A' && c <= 'Z') ? c + 32 : c;
        if (!((out[i] >= 'a' && out[i] <= 'z') || (out[i] >= '0' && out[i] <= '9') || out[i] == '.' || out[i] == '_' || out[i] == '-'))
            out[i] = '-';   /* accenti e simboli, byte per byte ("UNITÀ USB" → "unit--usb"), come tod-usb */
    }
    out[i] = 0;
}

static int nome_usato(const char *nome) {   /* nostro, o di un altro disco servito da LKL */
    for (int i = 0; i < nvol; i++) if (vol[i].montato && !strcmp(vol[i].nome, nome)) return 1;
    char a[300], p[600]; alias_di(nome, a, sizeof a);
    percorso(p, sizeof p, "lkl-%s.sock", a);
    struct stat st;
    return !lstat(p, &st);
}

static void scrivi_volumi(void) {
    char p[512], t[520];
    percorso(p, sizeof p, "lkl-%s.volumi", ID);
    snprintf(t, sizeof t, "%s.tmp", p);
    FILE *f = fopen(t, "w");
    if (!f) return;
    for (int i = 0; i < nvol; i++)
        if (vol[i].montato)
            fprintf(f, "%s\t%s\t%s\t%s\t%llu\t%s\t%s\t%s\n", vol[i].nome, ID, tipo_disco(), *prodotto ? prodotto : marca_modello,
                    (unsigned long long)vol[i].byte, vol[i].fs.tipo, vol[i].fs.etichetta, vol[i].fs.uuid);
    fclose(f);
    rename(t, p);
    scrivi_spazio();
}

static int ascolta(const char *p) {
    int l = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s", p);
    unlink(p);
    if (l < 0 || bind(l, (struct sockaddr *)&a, sizeof a) || listen(l, 16)) { if (l >= 0) close(l); return -1; }
    return l;
}

static void segna_espulso(void) {   /* lkl-ID.espulso: c'è solo se nessuna partizione è montata */
    char p[512]; int resta = 0;
    for (int j = 0; j < nvol; j++) resta |= vol[j].montato;
    percorso(p, sizeof p, "lkl-%s.espulso", ID);
    if (resta) unlink(p); else { FILE *e = fopen(p, "w"); if (e) fclose(e); }
}

/* tutte le partizioni (SOLO = 0: rilegge anche l'elenco) o solo la partizione SOLO (mount da terminale) */
static void monta_tutto(int solo) {
    int trovate = 0, minuti = 0;
    if (!solo) nparti = 0;
    { time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm); minuti = tm.tm_gmtoff / 60; }
    lkl_sys_mkdir("/dev", 0700);
    for (int p = 1; p <= 64 + 1 && nvol < 64; p++) {
        int part = p <= 64 ? p : 0;
        if (part == 0 && trovate) break;   /* il disco intero solo se non ha partizioni (superfloppy) */
        uint32_t dev;
        if (lkl_get_virtio_blkdev(disk_id, part, &dev)) continue;
        if (part) trovate++;
        if (solo && part != solo) continue;
        char nodo[64]; snprintf(nodo, sizeof nodo, "/dev/p%d", part);
        lkl_sys_mknod(nodo, LKL_S_IFBLK | 0600, dev);
        int fd = lkl_sys_open(nodo, LKL_O_RDONLY, 0);
        struct volume *v = &vol[nvol];
        for (int j = 0; solo && j < nvol; j++) if (vol[j].part == part) { if (vol[j].montato) { if (fd >= 0) lkl_sys_close(fd); lkl_sys_unlink(nodo); return; } v = &vol[j]; }
        int nuovo = v == &vol[nvol];
        memset(v, 0, sizeof *v);
        v->part = part;
        if (fd < 0) continue;
        long long fine = lkl_sys_lseek(fd, 0, LKL_SEEK_END);
        v->byte = fine > 0 ? (uint64_t)fine : 0;
        int ok = !prova_fs(fd, &v->fs);
        lkl_sys_close(fd);
        lkl_sys_unlink(nodo);
        if (!solo && nparti < 65) {
            struct parte *q = &parti[nparti++];
            q->n = part; q->byte = v->byte; q->fs = v->fs;
            char sp[128]; snprintf(sp, sizeof sp, "/sysfs/block/vda/vda%d/start", part);
            long st = part ? leggi_numero(sp) : 0;
            q->inizio = st > 0 ? (uint64_t)st * 512 : 0;
        }
        if (!ok) continue;
        /* orari giusti su FAT/exFAT (salvano l'ora locale), nomi in UTF-8. Supporto protetto: sola lettura,
         * e ext3/4, xfs e btrfs senza rigiocare il giornale (scriverebbero) */
        v->ro = protetto;
        char opz[128] = "";
        if (!strcmp(v->fs.driver, "vfat")) snprintf(opz, sizeof opz, "iocharset=utf8,codepage=850,time_offset=%d,usefree", minuti);   /* nomi 8.3 di Windows; usefree: lo spazio libero dal settore FSInfo (FAT32), come Windows, senza leggere tutta la FAT */
        else if (!strcmp(v->fs.driver, "exfat")) snprintf(opz, sizeof opz, "iocharset=utf8,time_offset=%d", minuti);
        else if (!strcmp(v->fs.driver, "ntfs3")) snprintf(opz, sizeof opz, "iocharset=utf8");
        else if (v->ro && !strcmp(v->fs.driver, "ext4")) snprintf(opz, sizeof opz, "noload");
        else if (v->ro && !strcmp(v->fs.driver, "xfs")) snprintf(opz, sizeof opz, "norecovery");
        else if (v->ro && !strcmp(v->fs.driver, "btrfs")) snprintf(opz, sizeof opz, "rescue=nologreplay");
        long r = lkl_mount_dev(disk_id, part, v->fs.driver, v->ro ? LKL_MS_RDONLY : 0, *opz ? opz : NULL, v->dove, sizeof v->dove);
        if (r && !v->ro) {   /* file system che Linux monta solo in lettura (NTFS da riparare, ext4 con funzioni nuove) */
            v->ro = 1;
            r = lkl_mount_dev(disk_id, part, v->fs.driver, LKL_MS_RDONLY, *opz ? opz : NULL, v->dove, sizeof v->dove);
            if (!r) logf_("partizione %d: solo in lettura (il file system non si lascia scrivere)", part);
        }
        if (r) { logf_("partizione %d (%s): non montata, %s", part, v->fs.tipo, lkl_strerror(r)); continue; }
        /* il nome: l'etichetta o, senza, il tipo di disco; con un numero se già usato */
        char base[256];
        snprintf(base, sizeof base, "%s", *v->fs.etichetta ? v->fs.etichetta : tipo_disco());
        for (char *c = base; *c; c++) if (*c == '/') *c = '_';
        snprintf(v->nome, sizeof v->nome, "%s", base);
        for (int k = 2; nome_usato(v->nome); k++) snprintf(v->nome, sizeof v->nome, "%s %d", base, k);
        alias_di(v->nome, v->alias, sizeof v->alias);
        percorso(v->sock, sizeof v->sock, "lkl-%s.sock", v->alias);
        for (int c = 0; c < MAXCLIENT; c++) v->client[c] = -1;
        v->ascolto = ascolta(v->sock);
        if (v->ascolto < 0) { logf_("%s: canale non aperto", v->nome); lkl_umount_dev(disk_id, part, 0, 1000); continue; }
        v->montato = 1;
        if (nuovo) nvol++;
        logf_("partizione %d: %s \"%s\" (%s) in Esplora file come \"%s\"%s", part, v->fs.tipo, v->fs.etichetta, v->fs.uuid, v->nome,
              v->ro ? ", sola lettura" : "");
    }
    scrivi_volumi();
    scrivi_parti();
    segna_espulso();
}

static void montaggi_lkl(const char *dove);

/* smonta in sicurezza: via il canale, chiuse le sessioni aperte, poi lo smontaggio */
static void smonta(struct volume *v) {
    pthread_mutex_lock(&vol_lock);
    if (!v->montato) { pthread_mutex_unlock(&vol_lock); return; }
    v->montato = 0;
    if (v->ascolto >= 0) close(v->ascolto);
    v->ascolto = -1;
    unlink(v->sock);
    for (int c = 0; c < MAXCLIENT; c++) if (v->client[c] >= 0) shutdown(v->client[c], SHUT_RDWR);
    pthread_mutex_unlock(&vol_lock);
    pthread_mutex_lock(&spazio_lock);   /* un calcolo dello spazio in corso finisce prima */
    pthread_mutex_unlock(&spazio_lock);
    lkl_sys_sync();
    long r = -1;
    for (int i = 0; i < 30 && r; i++) {   /* le sessioni chiudono i loro file */
        r = lkl_umount_dev(disk_id, v->part, 0, 100);
        if (r) usleep(100000);
    }
    if (r) { logf_("%s: smontaggio non riuscito (%s): la stacco", v->nome, lkl_strerror(r)); lkl_umount_dev(disk_id, v->part, 2 /* MNT_DETACH */, 100); }
    /* in LKL chi chiama è un thread del kernel: Linux chiude davvero il file system (put_super: giornale
     * chiuso, "da recuperare" spento) poco dopo, in un lavoro rimandato. Finché non l'ha fatto la partizione
     * non si apre in esclusiva: si aspetta quello, sennò il disco resterebbe "non pulito" (e chi lo legge
     * subito dopo, fsck o lo spegnimento, troverebbe il file system ancora aperto) */
    uint32_t dev;
    if (!lkl_get_virtio_blkdev(disk_id, v->part, &dev)) {
        char nodo[32]; snprintf(nodo, sizeof nodo, "/dev/x%d", v->part);
        lkl_sys_mknod(nodo, LKL_S_IFBLK | 0600, dev);
        int i, f = -1;
        for (i = 0; i < 100; i++) {
            f = lkl_sys_open(nodo, LKL_O_RDONLY | LKL_O_EXCL, 0);
            if (f >= 0) break;
            usleep(50000);
        }
        if (f >= 0) lkl_sys_close(f); else logf_("%s: ancora occupata dopo 5 s", v->nome);
        lkl_sys_unlink(nodo);
    }
    logf_("smontata %s", v->nome);
    if (getenv("TOD_LKL_DEBUG") && !strcmp(v->fs.driver, "ext4")) {   /* diagnosi: il superblocco dopo lo smontaggio */
        uint32_t dev; unsigned char sb[1024];
        if (!lkl_get_virtio_blkdev(disk_id, v->part, &dev)) {
            lkl_sys_mknod("/dev/diag", LKL_S_IFBLK | 0600, dev);
            int f = lkl_sys_open("/dev/diag", LKL_O_RDONLY, 0);
            if (f >= 0 && lkl_sys_pread64(f, (char *)sb, 1024, 1024) == 1024)
                logf_("[diag] %s dopo lo smontaggio: incompat=%#x (recover=%d), liberi=%u", v->nome, u32(sb + 0x60), (u32(sb + 0x60) & 4) != 0, u32(sb + 0x10));
            if (f >= 0) lkl_sys_close(f);
            lkl_sys_unlink("/dev/diag");
        }
        montaggi_lkl("dopo lo smontaggio");
    }
    scrivi_volumi();
    scrivi_parti();
}

static void montaggi_lkl(const char *dove) {   /* diagnosi (TOD_LKL_DEBUG): i montaggi veri dentro LKL */
    if (!getenv("TOD_LKL_DEBUG")) return;
    char b[2048] = ""; int f = lkl_sys_open("/proc/mounts", LKL_O_RDONLY, 0);
    if (f >= 0) { long n = lkl_sys_read(f, b, sizeof b - 1); if (n > 0) b[n] = 0; lkl_sys_close(f); }
    for (char *c = b; *c; c++) if (*c == '\n') *c = '|';
    logf_("[%s] montaggi: %s", dove, b);
}

static void pulisci_file(void) {
    char p[512];
    for (int i = 0; i < nvol; i++) if (vol[i].montato) unlink(vol[i].sock);
    percorso(p, sizeof p, "lkl-%s.volumi", ID); unlink(p);
    percorso(p, sizeof p, "lkl-%s.ctl", ID); unlink(p);
    percorso(p, sizeof p, "lkl-%s.blk", ID); unlink(p);
    percorso(p, sizeof p, "lkl-%s.parti", ID); unlink(p);
    percorso(p, sizeof p, "lkl-%s.espulso", ID); unlink(p);
    percorso(p, sizeof p, "lkl-%s.spazio", ID); unlink(p);
    percorso(p, sizeof p, "lkl-%s.vuoto", ID); unlink(p);
    percorso(p, sizeof p, "lkl-%s.pid", ID); unlink(p);
}

/* ---------- il disco grezzo per i comandi da terminale (tod-disco.c) ----------
 * "APRI <partizione> <0|1>\n" (0 = disco intero, 1 = per scrivere) → "OK <byte> <settore> <ro>\n" o "ERR <motivo>\n";
 * poi richieste {op, posizione (8 byte), lunghezza (4 byte)}: 'R' leggi, 'W' scrivi (seguono i dati), 'F' fsync,
 * 'P' rileggi la tabella delle partizioni, 'Q' fine. Risposta: esito (4 byte, 0 o -errno), poi i dati di 'R'.
 * Tutto passa da LKL (il nodo del disco), così la sua cache resta coerente con i montaggi di dopo. */

static pthread_mutex_t grezzo_lock = PTHREAD_MUTEX_INITIALIZER;
static int scrittori, aperti, sporco, in_pausa;   /* chi scrive: partizioni smontate; si rimonta quando non c'è più nessuno */

static void rileggi_e_rimonta(void) {   /* dopo fdisk o mkfs: tabella riletta, partizioni (nuove) montate */
    uint32_t dev;
    if (!lkl_get_virtio_blkdev(disk_id, 0, &dev)) {
        lkl_sys_mknod("/dev/intero", LKL_S_IFBLK | 0600, dev);
        int f = lkl_sys_open("/dev/intero", LKL_O_RDONLY, 0);
        if (f >= 0) {   /* "occupato" per un attimo: i file chiusi da poco si rilasciano in ritardo */
            long r = -LKL_EBUSY;
            for (int i = 0; i < 20 && r == -LKL_EBUSY; i++) { r = lkl_sys_ioctl(f, LKL_BLKRRPART, 0); if (r == -LKL_EBUSY) usleep(100000); }
            if (r) logf_("tabella delle partizioni non riletta: %s", lkl_strerror(r));
            lkl_sys_close(f);
        }
        lkl_sys_unlink("/dev/intero");
    }
    nvol = 0;
    memset(vol, 0, sizeof vol);
    monta_tutto(0);
}

static int tutto_n(int fd, void *b, size_t n, int scrivi) {
    for (size_t f = 0; f < n;) {
        ssize_t r = scrivi ? write(fd, (char *)b + f, n - f) : read(fd, (char *)b + f, n - f);
        if (r <= 0) return -1;
        f += r;
    }
    return 0;
}

static void *grezzo_thread(void *arg) {
    int c = (int)(intptr_t)arg, part = -1, rw = 0, fd = -1;
    char riga[64] = ""; size_t k = 0;
    while (k < sizeof riga - 1 && read(c, riga + k, 1) == 1 && riga[k] != '\n') k++;
    riga[k] = 0;
    char nodo[32], risp[96];
    uint32_t dev;
    if (sscanf(riga, "APRI %d %d", &part, &rw) != 2 || lkl_get_virtio_blkdev(disk_id, part, &dev)) {
        if (write(c, "ERR partizione\n", 15) < 0) {}
        close(c); return NULL;   /* (non conta tra gli aperti) */
    }
    if (rw && (protetto || cambiato)) { if (write(c, "ERR protetto\n", 13) < 0) {} close(c); return NULL; }
    pthread_mutex_lock(&grezzo_lock);
    aperti++;
    if (rw) {   /* chi cambia il disco lo vuole tutto per sé: via i montaggi (Esplora file, sessioni sftp) */
        sporco = 1;
        if (scrittori++ == 0) {
            int c2 = 0; for (int i = 0; i < nvol; i++) c2 |= vol[i].montato;
            if (c2) logf_("un comando scrive sul disco: partizioni smontate");
            for (int i = 0; i < nvol; i++) smonta(&vol[i]);
        }
    }
    pthread_mutex_unlock(&grezzo_lock);
    if (getenv("TOD_LKL_DEBUG")) { logf_("grezzo: apre %d per %s", part, rw ? "scrivere" : "leggere"); montaggi_lkl("apertura"); }
    snprintf(nodo, sizeof nodo, "/dev/g%d-%d", part, c);
    lkl_sys_mknod(nodo, LKL_S_IFBLK | 0600, dev);
    fd = lkl_sys_open(nodo, rw ? LKL_O_RDWR : LKL_O_RDONLY, 0);
    lkl_sys_unlink(nodo);
    if (fd < 0) {
        snprintf(risp, sizeof risp, "ERR %s\n", lkl_strerror(fd));
        if (write(c, risp, strlen(risp)) < 0) {}
    } else {
        long long n = lkl_sys_lseek(fd, 0, LKL_SEEK_END);
        snprintf(risp, sizeof risp, "OK %lld %u %d\n", n, blocco, protetto);
        if (write(c, risp, strlen(risp)) < 0) {}
        unsigned char h[13];
        size_t cap = 1 << 20; char *b = malloc(cap);
        while (b && !tutto_n(c, h, 13, 0)) {
            uint64_t off = 0; uint32_t len = 0;
            for (int i = 0; i < 8; i++) off |= (uint64_t)h[1 + i] << (8 * i);
            for (int i = 0; i < 4; i++) len |= (uint32_t)h[9 + i] << (8 * i);
            int32_t esito = 0;
            if (h[0] == 'Q') break;
            if ((h[0] == 'R' || h[0] == 'W') && len > cap) { char *nb = realloc(b, len); if (!nb) break; b = nb; cap = len; }
            if (h[0] == 'R') {
                long r = lkl_sys_pread64(fd, b, len, off);
                esito = r < 0 ? (int32_t)r : (int32_t)0;
                if (r >= 0 && (uint32_t)r < len) memset(b + r, 0, len - r);
                if (tutto_n(c, &esito, 4, 1) || (!esito && tutto_n(c, b, len, 1))) break;
                continue;
            }
            if (h[0] == 'W') {
                if (tutto_n(c, b, len, 0)) break;
                long r = rw ? lkl_sys_pwrite64(fd, b, len, off) : -LKL_EBADF;
                esito = r < 0 ? (int32_t)r : r == (long)len ? 0 : -LKL_EIO;
            } else if (h[0] == 'F') esito = (int32_t)lkl_sys_fsync(fd);
            else if (h[0] == 'P') {   /* BLKRRPART: si fa alla chiusura, quando nessuno ha il disco aperto */
                esito = 0;
            } else esito = -LKL_EINVAL;
            if (tutto_n(c, &esito, 4, 1)) break;
        }
        free(b);
        if (rw) lkl_sys_fsync(fd);
        lkl_sys_close(fd);
    }
    close(c);
    pthread_mutex_lock(&grezzo_lock);
    if (rw) scrittori--;
    if (--aperti == 0 && sporco && !in_pausa) { sporco = 0; logf_("comando finito: rileggo le partizioni"); rileggi_e_rimonta(); }
    pthread_mutex_unlock(&grezzo_lock);
    return NULL;
}

/* ---------- connessioni da Esplora file ---------- */

struct conn { struct volume *v; int fd, slot; };

static void *conn_thread(void *arg) {
    struct conn *c = arg;
    char riga[300]; size_t k = 0;   /* "VOL <nome>": il canale è già quello della partizione */
    while (k < sizeof riga - 1 && read(c->fd, riga + k, 1) == 1 && riga[k] != '\n') k++;
    if (c->v->montato) sftp_sessione(c->fd, c->v->dove, c->v->ro);
    pthread_mutex_lock(&vol_lock);
    c->v->client[c->slot] = -1;
    pthread_mutex_unlock(&vol_lock);
    close(c->fd);
    free(c);
    return NULL;
}

static void accetta(struct volume *v) {
    int fd = accept4(v->ascolto, NULL, NULL, SOCK_CLOEXEC);
    if (fd < 0) return;
    pthread_mutex_lock(&vol_lock);
    int slot = -1;
    for (int i = 0; i < MAXCLIENT && slot < 0; i++) if (v->client[i] < 0) slot = i;
    if (slot >= 0) v->client[slot] = fd;
    pthread_mutex_unlock(&vol_lock);
    if (slot < 0) { close(fd); return; }
    struct conn *c = malloc(sizeof *c);
    *c = (struct conn){v, fd, slot};
    pthread_t t;
    pthread_create(&t, NULL, conn_thread, c);
    pthread_detach(t);
}

/* ---------- controllo del disco ogni 2 s: scollegato, supporto tolto o cambiato ---------- */

static const char *immagine;   /* --file: la prova "scollegato" è il file che sparisce */
/* prove: TOD_LKL_RITARDO_MS fa aspettare ogni richiesta all'immagine come un hard disk vero */
static int ritardo_ms;
static int lento_request(struct lkl_disk d, struct lkl_blk_req *req) {
    usleep(ritardo_ms * 1000);
    return lkl_dev_blk_ops.request(d, req);
}
static struct lkl_dev_blk_ops lento_ops;
static volatile int esito_uscita = -1;

static void *sorveglia_disco(void *arg) {
    (void)arg;
    while (esito_uscita < 0 && !fermati) {
        sleep(2);
        if (immagine) { if (access(immagine, F_OK)) esito_uscita = 3; continue; }
        if (cambiato) { esito_uscita = 4; break; }
        pthread_mutex_lock(&usb_lock);
        int r = pronto();
        if (r == 0) {   /* stesso supporto? la capacità non deve cambiare */
            uint64_t prima = blocchi; uint32_t pb = blocco;
            if (!capacita() && (blocchi != prima || blocco != pb)) r = 2;
            blocchi = prima; blocco = pb;
        }
        pthread_mutex_unlock(&usb_lock);
        if (r < 0) esito_uscita = 3;
        else if (r > 0) esito_uscita = 4;
    }
    return NULL;
}

static void al_segnale(int s) { (void)s; fermati = 1; }

int main(int argc, char **argv) {
    struct lkl_disk disk = {0};
    signal(SIGPIPE, SIG_IGN);
    sigset_t m; sigemptyset(&m); sigaddset(&m, SIGTERM); sigaddset(&m, SIGINT);
    pthread_sigmask(SIG_UNBLOCK, &m, NULL);   /* Android li può lasciare bloccati ai processi di Termux */
    struct sigaction sa = {.sa_handler = al_segnale};
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    if (argc == 5 && !strcmp(argv[1], "--file")) {
        immagine = argv[2]; RUN = argv[3]; ID = argv[4];
        disk.fd = open(immagine, getenv("TOD_LKL_RO") ? O_RDONLY | O_CLOEXEC : O_RDWR | O_CLOEXEC);
        protetto = getenv("TOD_LKL_RO") != NULL;   /* prove: come una scheda con la levetta */
        if (disk.fd < 0) { logf_("%s: %s", immagine, strerror(errno)); return 1; }
        snprintf(prodotto, sizeof prodotto, "Disco di prova");
        struct stat st;
        if (!fstat(disk.fd, &st)) blocchi = st.st_size / 512;   /* blocco resta 512 */
        if ((ritardo_ms = getenv("TOD_LKL_RITARDO_MS") ? atoi(getenv("TOD_LKL_RITARDO_MS")) : 0) > 0) {
            lento_ops = lkl_dev_blk_ops; lento_ops.request = lento_request; disk.ops = &lento_ops;
        }
    } else if (argc == 4) {
        RUN = argv[1]; ID = argv[2];
    } else {
        fprintf(stderr, "uso: tod-lkl RUN ID FD | tod-lkl --file IMMAGINE RUN ID\n");
        return 2;
    }
    char p[512];
    percorso(p, sizeof p, "%s", "traccia");
    if (!access(p, F_OK)) {
        percorso(p, sizeof p, "traccia-%s.txt", ID);
        traccia = fopen(p, "w");
        ms_avvio = ms_ora();
    }
    percorso(p, sizeof p, "lkl-%s.pid", ID);
    FILE *pf = fopen(p, "w"); if (pf) { fprintf(pf, "%d\n", getpid()); fclose(pf); }

    senza_anticipo = getenv("TOD_LKL_ANTICIPO") && !strcmp(getenv("TOD_LKL_ANTICIPO"), "0");
    if (!immagine) {
        int r = usb_apri(atoi(argv[3]));
        if (r) { logf_("non è un disco USB utilizzabile (errore %d)", r); pulisci_file(); return 1; }
        logf_("%s (%s, %04x:%04x)", *prodotto ? prodotto : "?", marca_modello, vid, pid);
        /* lettore di schede vuoto: si aspetta la scheda */
        int r2, avvisato = 0;
        while ((r2 = pronto()) != 0) {
            if (r2 < 0 || fermati) { pulisci_file(); return r2 < 0 ? 3 : 0; }
            if (!avvisato++) {   /* lkl-ID.vuoto: il servizio non aspetta le sue partizioni */
                logf_("nessun supporto: aspetto");
                char v[512]; percorso(v, sizeof v, "lkl-%s.vuoto", ID);
                FILE *fv = fopen(v, "w"); if (fv) fclose(fv);
            }
            sleep(2);
        }
        { char v[512]; percorso(v, sizeof v, "lkl-%s.vuoto", ID); unlink(v); }
        if (capacita()) { logf_("capacità non leggibile"); pulisci_file(); return 1; }
        protetto = legge_protezione();
        disk.ops = &usb_ops;
        logf_("%.1f GB, blocchi da %u byte%s", blocchi * (double)blocco / 1e9, blocco, protetto ? ", protetto da scrittura" : "");
    }

    if (lkl_init(&lkl_host_ops) < 0) { logf_("LKL non si avvia"); pulisci_file(); return 1; }
    disk_id = lkl_disk_add(&disk);
    if (disk_id < 0) { logf_("disco non aggiunto: %s", lkl_strerror(disk_id)); pulisci_file(); return 1; }
    long r = lkl_start_kernel("mem=128M loglevel=3");
    if (r) { logf_("kernel: %s", lkl_strerror(r)); pulisci_file(); return 1; }
    /* i dati scritti arrivano sul disco entro ~2 s (Linux li terrebbe fino a 30 s): chi stacca la chiavetta
     * senza espellerla perde al massimo gli ultimi istanti */
    if (lkl_mount_fs("proc") == 0) {
        const char *k[][2] = {{"/proc/sys/vm/dirty_expire_centisecs", "200"}, {"/proc/sys/vm/dirty_writeback_centisecs", "100"}};
        for (int i = 0; i < 2; i++) { int f = lkl_sys_open(k[i][0], LKL_O_WRONLY, 0); if (f >= 0) { lkl_sys_write(f, k[i][1], strlen(k[i][1])); lkl_sys_close(f); } }
    }
    monta_tutto(0);
    armato = 1;
    if (!nvol) logf_("nessuna partizione leggibile");

    percorso(p, sizeof p, "lkl-%s.ctl", ID);
    int ctl = ascolta(p);
    percorso(p, sizeof p, "lkl-%s.blk", ID);
    int blk = ascolta(p);
    pthread_t sd;
    pthread_create(&sd, NULL, sorveglia_disco, NULL);
    pthread_detach(sd);

    while (!fermati && esito_uscita < 0) {
        struct pollfd pf_[67]; struct volume *chi[67]; int n = 0;
        if (ctl >= 0) { pf_[n] = (struct pollfd){ctl, POLLIN, 0}; chi[n++] = NULL; }
        if (blk >= 0) { pf_[n] = (struct pollfd){blk, POLLIN, 0}; chi[n++] = (struct volume *)&blk; }
        for (int i = 0; i < nvol; i++) if (vol[i].montato) { pf_[n] = (struct pollfd){vol[i].ascolto, POLLIN, 0}; chi[n++] = &vol[i]; }
        if (poll(pf_, n, 1000) <= 0) continue;
        for (int i = 0; i < n; i++) {
            if (!(pf_[i].revents & POLLIN)) continue;
            if (chi[i] == (struct volume *)&blk) {
                int c = accept4(blk, NULL, NULL, SOCK_CLOEXEC);
                if (c >= 0) { pthread_t t; pthread_create(&t, NULL, grezzo_thread, (void *)(intptr_t)c); pthread_detach(t); }
                continue;
            }
            if (chi[i]) { accetta(chi[i]); continue; }
            int c = accept4(ctl, NULL, NULL, SOCK_CLOEXEC);
            if (c < 0) continue;
            char cmd[300] = ""; size_t k = 0;
            struct pollfd cp = {c, POLLIN, 0};
            while (k < sizeof cmd - 1 && poll(&cp, 1, 2000) > 0 && read(c, cmd + k, 1) == 1 && cmd[k] != '\n') k++;
            cmd[k] = 0;
            if (!strncmp(cmd, "espelli ", 8)) {
                int trovato = 0;
                for (int j = 0; j < nvol; j++) if (vol[j].montato && !strcmp(vol[j].nome, cmd + 8)) { smonta(&vol[j]); trovato = 1; }
                if (write(c, trovato ? "ok\n" : "sconosciuto\n", trovato ? 3 : 12) < 0) {}
                segna_espulso();
                lkl_sys_sync();
            } else if (!strncmp(cmd, "monta ", 6)) {
                pthread_mutex_lock(&grezzo_lock);
                int prima = 0, dopo = 0, n = atoi(cmd + 6);
                for (int j = 0; j < nvol; j++) prima += vol[j].montato;
                if (n > 0 && !scrittori) monta_tutto(n);
                for (int j = 0; j < nvol; j++) dopo += vol[j].montato;
                pthread_mutex_unlock(&grezzo_lock);
                if (write(c, dopo > prima ? "ok\n" : "errore\n", dopo > prima ? 3 : 7) < 0) {}
            } else if (!strcmp(cmd, "aggiorna")) {   /* Dischi: lo spazio usato adesso (e pronto alla risposta) */
                pthread_mutex_lock(&spazio_lock); scrivi_spazio_ora(); pthread_mutex_unlock(&spazio_lock);
                if (write(c, "ok\n", 3) < 0) {}
            } else if (!strcmp(cmd, "pausa")) {
                pthread_mutex_lock(&grezzo_lock);
                in_pausa = 1;
                int c2 = 0; for (int j = 0; j < nvol; j++) c2 |= vol[j].montato;
                if (c2) logf_("un comando da terminale cambia il disco: partizioni smontate");
                for (int j = 0; j < nvol; j++) smonta(&vol[j]);
                lkl_sys_sync();
                pthread_mutex_unlock(&grezzo_lock);
                if (write(c, "ok\n", 3) < 0) {}
            } else if (!strcmp(cmd, "riprendi")) {
                pthread_mutex_lock(&grezzo_lock);
                if (in_pausa) {
                    in_pausa = 0; sporco = 0;
                    if (!aperti) { logf_("comando finito: rileggo le partizioni"); rileggi_e_rimonta(); }
                    else sporco = 1;   /* lo farà l'ultimo che chiude */
                }
                pthread_mutex_unlock(&grezzo_lock);
                if (write(c, "ok\n", 3) < 0) {}
            } else if (!strcmp(cmd, "fine")) {
                fermati = 1;
                if (write(c, "ok\n", 3) < 0) {}
            }
            close(c);
        }
    }
    int esito = esito_uscita >= 0 ? esito_uscita : 0;
    if (esito == 0) {   /* fermato o espulso: dati scritti e partizioni smontate */
        lkl_sys_sync();
        for (int i = 0; i < nvol; i++) smonta(&vol[i]);
        logf_("fermato");
    } else {
        logf_(esito == 3 ? "disco scollegato" : "supporto tolto o cambiato");
        if (esito == 4) { percorso(p, sizeof p, "lkl-%s.riapri", ID); FILE *e = fopen(p, "w"); if (e) fclose(e); }   /* tod-usb lo riapre */
    }
    pulisci_file();
    if (ctl >= 0) close(ctl);
    if (blk >= 0) close(blk);
    if (esito == 0) lkl_sys_halt();
    _exit(esito);
}
