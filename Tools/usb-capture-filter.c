// Shrinks a live high-speed USB capture (pcapng on stdin → pcapng on stdout).
//
// A capture of the streaming camera is about 60 MB per second, almost all of it
// the host polling endpoints and the camera answering NAK, plus the image data.
// This filter drops start-of-frame packets and every token that was answered with
// NAK, and cuts long data packets to their first bytes (the original length is
// kept, so tools still see the full size). Long recordings then fit on disk.
//
// Build:  cc -O2 -o build/usb-capture-filter Tools/usb-capture-filter.c
// Use:    mkfifo capture.fifo
//         usb_sniffer --capture --speed hs --fold --fifo capture.fifo &
//         build/usb-capture-filter < capture.fifo > capture.pcapng
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { KEEP_DATA_BYTES = 40 };   // PID + 37 payload bytes + 2 CRC bytes

static uint8_t pending[65536];   // the last token, held until we know its answer
static size_t pending_size = 0;

static void emit(const uint8_t *block, size_t size) {
    fwrite(block, 1, size, stdout);
}

static int is_usb_link_type(uint16_t type) {
    return type == 288 || (type >= 293 && type <= 295);
}

int main(void) {
    static uint8_t block[1 << 20];
    uint16_t link_types[16] = {0};
    int interfaces = 0;

    for (;;) {
        if (fread(block, 1, 8, stdin) != 8) break;
        uint32_t type, length;
        memcpy(&type, block, 4);
        memcpy(&length, block + 4, 4);
        if (length < 12 || length > sizeof block) break;
        if (fread(block + 8, 1, length - 8, stdin) != length - 8) break;

        if (type == 1 && interfaces < 16) link_types[interfaces++] = (uint16_t)(block[8] | block[9] << 8);
        if (type != 6) { emit(block, length); continue; }

        uint32_t interface, captured;
        memcpy(&interface, block + 8, 4);
        memcpy(&captured, block + 20, 4);
        if (interface >= 16 || !is_usb_link_type(link_types[interface]) || captured == 0) {
            emit(block, length);
            continue;
        }

        uint8_t pid = block[28];
        if (pid == 0xA5) continue;                                     // SOF
        if (pid == 0x5A) { pending_size = 0; continue; }               // NAK: drop it and its token
        if (pid == 0x69 || pid == 0xE1 || pid == 0x2D || pid == 0xB4) { // token: wait for the answer
            memcpy(pending, block, length);
            pending_size = length;
            continue;
        }
        if (pending_size) { emit(pending, pending_size); pending_size = 0; }

        int is_data = pid == 0xC3 || pid == 0x4B || pid == 0x87 || pid == 0x0F;
        if (is_data && captured > KEEP_DATA_BYTES) {
            // Shorten the packet; the original length field (offset 24) stays.
            uint32_t new_captured = KEEP_DATA_BYTES;
            uint32_t padded = (new_captured + 3) & ~3u;
            uint32_t new_length = 28 + padded + 4;   // header + data + trailing length
            memcpy(block + 20, &new_captured, 4);
            memset(block + 28 + new_captured, 0, padded - new_captured);
            memcpy(block + 4, &new_length, 4);
            memcpy(block + new_length - 4, &new_length, 4);
            emit(block, new_length);
            continue;
        }
        emit(block, length);
    }
    fflush(stdout);
    return 0;
}
