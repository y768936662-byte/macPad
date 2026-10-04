/* CPU-only controls: reads a local file and the actual production header.
 * No hooks, processes, devices, sockets, thread creation or VM API calls.
 * cc -std=c11 -Wall -Wextra -Iinclude misc/test_vnc_profile.c -o test_vnc_profile
 * ./test_vnc_profile /path/to/the/reviewed/OSXvnc-server
 */
#include "macws_vnc_profile.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void put32(uint8_t *p,uint32_t value) { memcpy(p,&value,4); }
static void put64(uint8_t *p,uint64_t value) { memcpy(p,&value,8); }
static size_t find_command(uint8_t *bytes,uint32_t kind,const char *name) {
    size_t offset=32;
    for (uint32_t i=0;i<macws_vnc_u32(bytes+16);i++) {
        if (macws_vnc_u32(bytes+offset)==kind &&
            (!name || macws_vnc_name16(bytes+offset+8,name))) return offset;
        offset+=macws_vnc_u32(bytes+offset+4);
    }
    assert(!"required fixture command missing"); return 0;
}
static size_t find_section(uint8_t *bytes,size_t command,const char *name) {
    for (uint32_t i=0;i<macws_vnc_u32(bytes+command+64);i++) {
        size_t offset=command+72+(size_t)i*80;
        if (macws_vnc_name16(bytes+offset,name)) return offset;
    }
    assert(!"required fixture section missing"); return 0;
}
static int region_callback(void *client,MacWSVNCRegion region) {
    assert(client==(void *)(uintptr_t)0x1234);
    assert(region.extents.x1==-17 && region.extents.y1==23);
    assert(region.extents.x2==300 && region.extents.y2==400);
    return region.data ? (int)region.data->numRects : 1;
}

int main(int argc,char **argv) {
    assert(argc==2 && sizeof(void *)==8);
    FILE *file=fopen(argv[1],"rb"); assert(file);
    uint8_t header[32]; assert(fread(header,1,sizeof(header),file)==sizeof(header));
    size_t length=32+macws_vnc_u32(header+20);
    assert(length<=65568 && length>=32);
    uint8_t *original=malloc(length+24),*changed=malloc(length+24);
    assert(original && changed);
    assert(fseek(file,0,SEEK_SET)==0 && fread(original,1,length,file)==length);
    fclose(file);
    MacWSVNCImageProfile profile={0};
    assert(macws_vnc_parse_profile(original,length,&profile));
    assert(profile.textOffset==0x2c18 && profile.textSize==0x4d6a0);
    #define RESET() memcpy(changed,original,length)
    #define REJECT() assert(!macws_vnc_parse_profile(changed,length,&profile))
    RESET(); changed[find_command(changed,0x1b,NULL)+8]^=1; REJECT();
    RESET(); put32(changed+8,2); REJECT(); /* wrong ARM64 subtype */
    RESET(); put32(changed+12,0xa); REJECT(); /* MH_DSYM */
    RESET(); put32(changed+16,0xffffffff); REJECT();
    RESET(); put32(changed+32+4,0); REJECT();
    RESET(); put32(changed+32+4,9); REJECT();
    RESET(); size_t text=find_command(changed,0x19,"__TEXT");
    put64(changed+text+32,UINT64_MAX); REJECT();
    RESET(); text=find_command(changed,0x19,"__TEXT");
    put32(changed+text+60,7); REJECT(); /* writable code metadata */
    RESET(); text=find_command(changed,0x19,"__TEXT");
    size_t section=find_section(changed,text,"__text");
    put32(changed+section+48,0x2c1c); REJECT(); /* file/VM disagreement */
    RESET(); text=find_command(changed,0x19,"__TEXT");
    section=find_section(changed,text,"__text");
    put64(changed+section+40,0x4d6a4); REJECT();
    RESET(); size_t data=find_command(changed,0x19,"__DATA");
    section=find_section(changed,data,"__bss");
    put64(changed+section+32,0x100061670ULL); REJECT();
    RESET(); size_t uuid=find_command(changed,0x1b,NULL);
    memcpy(changed+length,changed+uuid,24);
    put32(changed+16,macws_vnc_u32(changed+16)+1);
    put32(changed+20,macws_vnc_u32(changed+20)+24);
    assert(!macws_vnc_parse_profile(changed,length+24,&profile));
    RESET(); assert(!macws_vnc_parse_profile(changed,length-1,&profile));
    assert(macws_vnc_parse_profile(original,length,&profile));
    for (unsigned i=0;i<MacWSVNCSymbolCount;i++) {
        const MacWSVNCPublicEntry *entry=&macws_vnc_public_profile[i];
        assert(macws_vnc_target_offset(&profile,entry->offset,entry->extent,entry->code));
    }
    assert(!macws_vnc_target_offset(&profile,0x79bf8,24,false));
    assert(!macws_vnc_target_offset(&profile,0x7a1e8,8,false));
    assert(!macws_vnc_target_offset(&profile,0x60000,32,true));
    assert(!macws_vnc_span(UINT64_MAX-1,4,UINT64_MAX-8,8));
    assert(!macws_vnc_span(0x64000,1,0x60000,0x4000));
    assert(macws_vnc_key_fits_wire(0,UINT32_MAX));
    assert(macws_vnc_key_fits_wire(1,0x1008ff12));
    assert(!macws_vnc_key_fits_wire(1,UINT64_C(1)<<40));
    assert(!macws_vnc_key_fits_wire(2,0xffe1));
    assert(!macws_vnc_key_fits_wire(-1,0xffe1));
    MacWSVNCRegion region={{-17,23,300,400},NULL};
    int (*callback)(void *,MacWSVNCRegion)=region_callback;
    assert(callback((void *)(uintptr_t)0x1234,region)==1);
    struct { int64_t size,numRects; MacWSVNCBox box; } dataRegion={1,2,{0,0,1,1}};
    region.data=(MacWSVNCRegionData *)&dataRegion;
    assert(callback((void *)(uintptr_t)0x1234,region)==2);
    free(changed); free(original);
    puts("VNC profile/header/RegionRec CPU controls passed (not runtime acceptance)");
    return 0;
}
