#ifndef MACWS_VNC_PROFILE_H
#define MACWS_VNC_PROFILE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* One RE-reviewed ARM64/ALL OSXvnc build; no historical-offset fallback.
 * All offsets are relative to the loaded Mach header. Signature-only changes
 * may resize LINKEDIT, but must not change the UUID/code/data/ObjC contract. */
static const uint8_t macws_vnc_profile_uuid[16] = {
    0xaa,0xc9,0x62,0xb1,0x0a,0x40,0x34,0xb7,
    0xbe,0xd3,0x4b,0xbc,0xf0,0xc4,0xd7,0xe3
};
static const uint8_t macws_vnc_profile_text_sha256[32] = {
    0x78,0x4b,0x08,0xf0,0xca,0xe3,0xaa,0x34,
    0xc1,0xbe,0xce,0x3c,0x7b,0x77,0x73,0x96,
    0x9f,0xb8,0xee,0xba,0xa6,0xaa,0xab,0x9e,
    0x11,0xa6,0x76,0xfe,0x7d,0x00,0xbb,0xcb
};

enum { MacWSVNCSymbolScreen, MacWSVNCSymbolRefresh, MacWSVNCSymbolGetFramebuffer,
       MacWSVNCSymbolGetRectangle, MacWSVNCSymbolSendUpdate, MacWSVNCSymbolReadExact,
       MacWSVNCSymbolNormalMessage, MacWSVNCSymbolCount };
typedef struct { const char *name; uint64_t offset; size_t extent; bool code; }
    MacWSVNCPublicEntry;
static const MacWSVNCPublicEntry macws_vnc_public_profile[] = {
    {"rfbScreen",0x61530,24,false}, {"refreshCallback",0x2e18,32,true},
    {"rfbGetFramebuffer",0x3674,32,true},
    {"rfbGetFramebufferUpdateInRect",0x38a0,32,true},
    {"rfbSendFramebufferUpdate",0x6c34,32,true},
    {"ReadExact",0xbeac,32,true}, {"rfbProcessClientNormalMessage",0x6188,32,true}
};
#define MACWS_VNC_SCALE_OFFSET UINT64_C(0x616b0)
#define MACWS_VNC_MODIFIERS_OFFSET 0x60
#define MACWS_VNC_INSTANCE_SIZE 0x30078

typedef struct { int16_t x1,y1,x2,y2; } MacWSVNCBox;
typedef struct { int64_t size, numRects; MacWSVNCBox rects[]; }
    MacWSVNCRegionData;
typedef struct { MacWSVNCBox extents; MacWSVNCRegionData *data; }
    MacWSVNCRegion;
_Static_assert(sizeof(MacWSVNCBox) == 8, "reviewed BoxRec ABI");
_Static_assert(sizeof(MacWSVNCRegion) == 16 &&
               offsetof(MacWSVNCRegion,data) == 8, "reviewed RegionRec ABI");
_Static_assert(offsetof(MacWSVNCRegionData,rects) == 16,
               "reviewed RegData ABI");

static inline bool macws_vnc_key_fits_wire(int down, uint64_t keysym) {
    return (down == 0 || down == 1) && keysym <= UINT32_MAX;
}
/* A separate, explicit diagnostic backend choice. Absence retains the full
 * shared-mmap profile. Unknown values leave the local output untouched and
 * are rejected by the installer before any hook/state/thread/socket work. */
static inline bool macws_vnc_select_frame_backend(const char *value,
                                                   bool *nativeCG) {
    if (!nativeCG) return false;
    if (!value || strcmp(value,"shared-mmap") == 0) {
        *nativeCG=false;
        return true;
    }
    if (strcmp(value,"native-cg") == 0) {
        *nativeCG=true;
        return true;
    }
    return false;
}
static inline bool macws_vnc_span(uint64_t start, uint64_t count,
                                   uint64_t base, uint64_t span) {
    return count != 0 && start >= base && start - base <= span &&
           count <= span - (start - base) && start <= UINT64_MAX - count;
}
static inline uint32_t macws_vnc_u32(const uint8_t *p) {
    uint32_t v; memcpy(&v,p,4); return v;
}
static inline uint64_t macws_vnc_u64(const uint8_t *p) {
    uint64_t v; memcpy(&v,p,8); return v;
}
static inline bool macws_vnc_name16(const uint8_t *p,const char *name) {
    size_t length = strlen(name);
    return length < 16 && memcmp(p,name,length) == 0 && p[length] == 0;
}

typedef struct { uint64_t textOffset,textSize; } MacWSVNCImageProfile;
/* Input is a SAFE COPY of exactly header+sizeofcmds, never arbitrary VM.
 * This routine binds every segment/section geometry used by the adapter.
 * Runtime separately checks actual VM permissions and the full code digest. */
static inline bool macws_vnc_parse_profile(const uint8_t *b,size_t length,
                                           MacWSVNCImageProfile *out) {
    if (!b || !out || length < 32 || macws_vnc_u32(b) != 0xfeedfacf ||
        macws_vnc_u32(b+4) != 0x100000c || macws_vnc_u32(b+8) != 0 ||
        macws_vnc_u32(b+12) != 2) return false;
    uint32_t count = macws_vnc_u32(b+16), bytes = macws_vnc_u32(b+20);
    if (!count || count > 128 || bytes > 65536 ||
        bytes != length-32) return false;
    size_t cursor = 32;
    unsigned segments = 0, sections = 0, uuids = 0;
    for (uint32_t i=0;i<count;i++) {
        if (cursor > length || length-cursor < 8) return false;
        const uint8_t *command=b+cursor;
        uint32_t kind=macws_vnc_u32(command), size=macws_vnc_u32(command+4);
        if (size < 8 || (size & 7) || size > length-cursor) return false;
        if (kind == 0x1b) {
            if (size != 24 || ++uuids != 1 ||
                memcmp(command+8,macws_vnc_profile_uuid,16)) return false;
        } else if (kind == 0x19) {
            if (size < 72) return false;
            uint64_t vm=macws_vnc_u64(command+24), span=macws_vnc_u64(command+32);
            uint64_t file=macws_vnc_u64(command+40), stored=macws_vnc_u64(command+48);
            uint32_t maxprot=macws_vnc_u32(command+56), prot=macws_vnc_u32(command+60);
            uint32_t nsections=macws_vnc_u32(command+64);
            if (span > UINT64_MAX-vm || stored > span ||
                stored > UINT64_MAX-file || nsections > (size-72)/80 ||
                size != 72+(size_t)nsections*80) return false;
            unsigned bit=0;
            if (macws_vnc_name16(command+8,"__PAGEZERO")) {
                bit=1;
                if (vm || span != UINT64_C(0x100000000) || file || stored ||
                    maxprot || prot || nsections) return false;
            } else if (macws_vnc_name16(command+8,"__TEXT")) {
                bit=2;
                if (vm != UINT64_C(0x100000000) || span != 0x5c000 ||
                    file || stored != 0x5c000 || maxprot != 5 || prot != 5) return false;
            } else if (macws_vnc_name16(command+8,"__DATA_CONST")) {
                bit=4;
                if (vm != UINT64_C(0x10005c000) || span != 0x4000 ||
                    file != 0x5c000 || stored != 0x4000 || maxprot != 3 || prot != 3) return false;
            } else if (macws_vnc_name16(command+8,"__DATA")) {
                bit=8;
                if (vm != UINT64_C(0x100060000) || span != 0x4000 ||
                    file != 0x60000 || stored != 0x4000 || maxprot != 3 || prot != 3) return false;
            } else if (macws_vnc_name16(command+8,"__LINKEDIT")) {
                bit=16;
                if (vm != UINT64_C(0x100064000) || file != 0x64000 ||
                    !span || span > 0x1000000 || !stored || maxprot != 1 ||
                    prot != 1 || nsections) return false;
            } else return false;
            if (segments & bit) return false;
            segments |= bit;
            for (uint32_t j=0;j<nsections;j++) {
                const uint8_t *section=command+72+(size_t)j*80;
                uint64_t addr=macws_vnc_u64(section+32), n=macws_vnc_u64(section+40);
                uint32_t off=macws_vnc_u32(section+48), flags=macws_vnc_u32(section+64);
                if (memcmp(section+16,command+8,16) || addr < vm ||
                    addr-vm > span || n > span-(addr-vm)) return false;
                unsigned type=flags & 0xff;
                if (type != 1 && type != 0xc && type != 0x12 &&
                    (off < file || (uint64_t)off-file != addr-vm ||
                     (uint64_t)off-file > stored || n > stored-((uint64_t)off-file))) return false;
                unsigned selected=0;
                if (bit==2 && macws_vnc_name16(section,"__text")) {
                    selected=1;
                    if (addr != UINT64_C(0x100002c18) || n != 0x4d6a0 ||
                        off != 0x2c18 || flags != 0x80000400) return false;
                } else if (bit==8 && macws_vnc_name16(section,"__common")) {
                    selected=2;
                    if (addr != UINT64_C(0x100061370) || n != 0x2f4 || off || flags != 1) return false;
                } else if (bit==8 && macws_vnc_name16(section,"__bss")) {
                    selected=4;
                    if (addr != UINT64_C(0x100061668) || n != 0x1009 || off || flags != 1) return false;
                }
                if (selected && (sections & selected)) return false;
                sections |= selected;
            }
        }
        cursor += size;
    }
    if (cursor != length || segments != 31 || sections != 7 || uuids != 1) return false;
    out->textOffset=0x2c18; out->textSize=0x4d6a0;
    return true;
}

static inline bool macws_vnc_target_offset(const MacWSVNCImageProfile *p,
                                            uint64_t offset,size_t size,bool code) {
    return p && (code ? macws_vnc_span(offset,size,p->textOffset,p->textSize)
                       : macws_vnc_span(offset,size,0x60000,0x4000));
}
/* Actual semantic pointer types extracted from this binary, not SDK guesses. */
static const char macws_vnc_client_argument_type[] = "^{rfbClientRec=i*ii{_opaque_pthread_mutex_t=q[56c]}iii^v^v[16C]{_opaque_pthread_mutex_t=q[56c]}{_opaque_pthread_cond_t=q[40c]}{_Region={_Box=ssss}^{_RegData}}{_Region={_Box=ssss}^{_RegData}}^?*{?=CCCCSSSCCCCS}i**i[17i][17i]iiiiii{z_stream_s=*IQ*IQ*^{internal_state}^?^?^viQQ}iI{z_stream_s=*IQ*IQ*^{internal_state}^?^?^viQQ}{z_stream_s=*IQ*IQ*^{internal_state}^?^?^viQQ}i*i*i[4{z_stream_s=*IQ*IQ*^{internal_state}^?^?^viQQ}][4i][4i]iiiiiiiiiiiiiiiiII{PALETTE_s=[256{PALETTE_ENTRY_s=^{COLOR_LIST_s}i}][256^{COLOR_LIST_s}][256{COLOR_LIST_s=^{COLOR_LIST_s}iI}]}i*i*^i{jpeg_destination_mgr=*Q^?^?^?}ii^{jpeg_compress_struct}[16388c]iiii^v^v**^vi^v^v^v^viii{CGPoint=dd}B[256B]^{screen_data_t}[30000c]I^{rfbClientRec}^{rfbClientRec}}";
static const char macws_vnc_server_argument_type[] = "^{rfbserver=@*iB{_opaque_pthread_mutex_t=q[56c]}{_opaque_pthread_cond_t=q[40c]}}";
#endif
