/*
 * Generates SwordKit's Android 37 java.lang.Character compatibility table.
 *
 * Inputs: ICU4C 78.3 headers/data (the ICU/Unicode version pinned by Android 37).
 * Output: One fixed-width little-endian row for every UTF-16 code unit after a 16-byte header.
 * Side effects: Replaces the output path supplied as argv[1].
 * Failure modes: Exits nonzero for the wrong ICU major/minor, missing output, or write failure.
 */
#include <stdint.h>
#include <stdio.h>
#include <unicode/uchar.h>
#include <unicode/uversion.h>

static int write_u16_le(FILE *output, uint16_t value) {
    return fputc(value & 0xFF, output) != EOF
        && fputc((value >> 8) & 0xFF, output) != EOF;
}

static int write_u32_le(FILE *output, uint32_t value) {
    return write_u16_le(output, value & 0xFFFF)
        && write_u16_le(output, (value >> 16) & 0xFFFF);
}

int main(int argc, char **argv) {
    UVersionInfo icu_version;
    if (argc != 2) {
        fprintf(stderr, "usage: %s OUTPUT\n", argv[0]);
        return 64;
    }
    u_getVersion(icu_version);
    if (icu_version[0] != 78 || icu_version[1] != 3) {
        fprintf(stderr, "ICU 78.3 required; found %u.%u\n", icu_version[0], icu_version[1]);
        return 65;
    }
    FILE *output = fopen(argv[1], "wb");
    if (output == NULL) {
        perror("fopen");
        return 66;
    }

    const unsigned char magic[8] = {'A', 'N', 'D', 'J', 'C', 'H', 'A', 'R'};
    if (fwrite(magic, 1, sizeof(magic), output) != sizeof(magic)
        || fputc(78, output) == EOF
        || fputc(3, output) == EOF
        || fputc(17, output) == EOF
        || fputc(0, output) == EOF
        || !write_u32_le(output, 65536)) {
        fclose(output);
        return 67;
    }

    for (uint32_t value = 0; value <= 0xFFFF; value++) {
        UChar32 upper = u_toupper((UChar32)value);
        uint16_t upper_unit = (uint16_t)upper;
        uint16_t lower_of_upper = (uint16_t)u_tolower((UChar32)upper_unit);
        uint16_t lowercase = (uint16_t)u_tolower((UChar32)value);
        unsigned char flags = 0;
        if (u_isalnum((UChar32)value)) flags |= 1;
        if (u_isdigit((UChar32)value)) flags |= 2;
        if (u_isWhitespace((UChar32)value)) flags |= 4;
        if (u_hasBinaryProperty((UChar32)value, UCHAR_CASED)) flags |= 8;
        if (u_hasBinaryProperty((UChar32)value, UCHAR_CASE_IGNORABLE)) flags |= 16;
        int32_t digit = u_digit((UChar32)value, 36);
        unsigned char encoded_digit = digit < 0 ? 0xFF : (unsigned char)digit;

        if (!write_u16_le(output, upper_unit)
            || !write_u16_le(output, lower_of_upper)
            || !write_u16_le(output, lowercase)
            || fputc(flags, output) == EOF
            || fputc(encoded_digit, output) == EOF) {
            fclose(output);
            return 68;
        }
    }
    return fclose(output) == 0 ? 0 : 69;
}
