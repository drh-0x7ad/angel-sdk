/*
 * Copyright (c) 2016, Seraphim Sense Ltd.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted
 * provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this list of conditions
 *    and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice, this list of
 *    conditions and the following disclaimer in the documentation and/or other materials provided
 *    with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors may be used to
 *    endorse or promote products derived from this software without specific prior written
 *    permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
 * CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING,
 * BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 * FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
 * OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 * TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
 * USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */


#import "ANHexWrapper.h"
#import "NSString+Angel.h"
#import "NSData+Angel.h"

#define FLASH_PAGE_BYTES 256
#define CRC_BYTES 2
#define PAGE_INDEX_BYTES 2
#define PAGE_ADDRESS_BYTES 4
#define PAGE_TYPE_BYTES 2
#define PAGE_OVERHEAD_BYTES (CRC_BYTES + PAGE_ADDRESS_BYTES + PAGE_INDEX_BYTES)
#define PAGE_PAYLOAD_BYTES (FLASH_PAGE_BYTES - PAGE_OVERHEAD_BYTES)
#define PAGE_PAYLOAD_START_BYTES (PAGE_INDEX_BYTES + PAGE_ADDRESS_BYTES + PAGE_TYPE_BYTES)

#define ROM_START 0x8000 // The first address in code memory
#define ROM_END   0x7FFFF // The last address in code memory

typedef uint16_t bit_order_16(uint16_t value);
typedef uint8_t bit_order_8(uint8_t value);

typedef enum {
    RecordTypeData = 0x00,
    RecordTypeEOF = 0x01,
    RecordTypeESA = 0x02,
    RecordTypeSSA = 0x03,
    RecordTypeELA = 0x04,
    RecordTypeSLA = 0x05
} RecordType;

@implementation ANBlock

- (instancetype)initWithIndex:(UInt16)index address:(UInt32)startAddress data:(NSData *)data {

    self = [super init];
    if (self) {
        _index =        index;
        _startAddress = startAddress;
        _data =         data;
    }
    return self;
}

- (NSData *)getBlock {
    
    NSMutableData *block = [NSMutableData dataWithCapacity:FLASH_PAGE_BYTES];
    NSLog(@"%d",_index);
    [block appendBytes:&_index length:2];
    
    UInt32 address = self.startAddress;
    [block appendBytes:&address length:sizeof(address)];
    [block appendData:self.data];
    
    UInt16 crc = crc16ccitt(block.bytes, 254);
    [block appendBytes:&crc length:sizeof(crc)];
    
//    NSLog(@"BLOCK %d\nAddress: 0x%05x\nData: %@\nCRC: %d", _index, _startAddress, _data, _CRC);
    return block;
}

uint8_t straight_8(uint8_t value) {
    return value;
}

uint16_t straight_16(uint16_t value) {
    return value;
}

uint16_t crc16(uint8_t const *message, int nBytes, bit_order_8(data_order), bit_order_16(remainder_order), uint16_t remainder, uint16_t polynomial) {
    for (int byte = 0; byte < nBytes; ++byte)
    {
        remainder ^= (data_order(message[byte]) << 8);
        for (uint8_t bit = 8; bit > 0; --bit)
        {
            if (remainder & 0x8000)
            {
                remainder = (remainder << 1) ^ polynomial;
            }
            else
            {
                remainder = (remainder << 1);
            }
        }
    }
    return remainder_order(remainder);
}

uint16_t crc16ccitt(uint8_t const *message, int nBytes) {
    return crc16(message, nBytes, straight_8, straight_16, 0xffff, 0x1021);
}

@end


@interface ANHexWrapper()

@property u_int8_t *bytes;
@property NSMutableArray *blocks;

@end

@implementation ANHexWrapper

- (instancetype)initWithHexFile:(NSString *)filePath {
    self = [super init];
    if (self) {
        NSError *error = nil;
        NSString *hexString = [NSString stringWithContentsOfFile:filePath encoding:NSASCIIStringEncoding error:&error];
        
        NSArray *stringLines = [hexString componentsSeparatedByString:@"\r\n"];
        
        self.bytes = malloc(sizeof(uint8_t) * (ROM_END - ROM_START));
        NSLog(@"%d", ROM_END - ROM_START);
        for (NSInteger i = 0; i < ROM_END - ROM_START; i++) {
            self.bytes[i] = 0xFF;
        }
        int addressOffset = 0x00;
        
        for (int i = 0; i < stringLines.count; i++)
        {
            NSString *container = stringLines[i];
            if ([container hasPrefix:@":"])
            {
                NSString *line = [container substringFromIndex:1];
                int type = [self typeFromLine:line];
                NSString *payload = [self payloadFromLine:line];
                if (payload)
                {
                    switch (type)
                    {
                        case RecordTypeData:
                        {
                            int index = [self addressFromLine:line] - ROM_START + addressOffset;
                            if (index >= 0)
                            {
                                for (int pointer = 0; pointer < payload.length / 2; pointer++)
                                {
                                    NSString *currentByte = [payload substringWithRange:NSMakeRange(pointer * 2, 2)];
                                    unsigned byte = 0;
                                    if ([[NSScanner scannerWithString:currentByte] scanHexInt:&byte])
                                    {
//                                        NSLog(@"address: 0x%02x\t value: 0x%02x", index + pointer + ROM_START, byte);
                                        self.bytes[index + pointer] = byte;
                                    }
                                }
                            }
                        } break;
                        case RecordTypeESA:
                        {
                            unsigned esa = 0;
                            if ([[NSScanner scannerWithString:payload] scanHexInt:&esa])
                            {
                                addressOffset = esa << 4;
                            }
                        } break;
                        default:
                        {
                            
                        } break;
                    }
                }
            }
            else
            {
                //stop with error
            }
        }
        
        _blocks = [@[] mutableCopy];
        _pages = 0;
        
        int index = 0;
        int bytesCount = [self bytesCount];
        
        while (index < bytesCount)
        {
            NSData *data = [self dataBlockForIndex:index length:PAGE_PAYLOAD_BYTES];
            if (![self isPageEmpty:data])
            {
                ANBlock *block = [[ANBlock alloc] initWithIndex:_pages address:ROM_START + index data:data];
                [_blocks addObject:block];
                _pages++;
            }

            index += PAGE_PAYLOAD_BYTES;
        }
    }
    return self;
}

- (BOOL)isPageEmpty:(NSData *)data
{
    const char *bytes = [data bytes];
    for (int i = 0; i < [data length]; i++)
    {
        if ((unsigned char)bytes[i] != 0xFF)
        {
            return NO;
        }
    }
    return YES;
}

- (int)typeFromLine:(NSString *)line {
    NSString *typeBytes = [line substringWithRange:NSMakeRange(PAGE_INDEX_BYTES + PAGE_ADDRESS_BYTES, PAGE_TYPE_BYTES)];
    unsigned type = 0;
    if ([[NSScanner scannerWithString:typeBytes] scanHexInt:&type]) {
        return type;
    }
    return 0;
}

- (int)addressFromLine:(NSString *)line {
    NSString *addressBytes = [line substringWithRange:NSMakeRange(PAGE_INDEX_BYTES, PAGE_ADDRESS_BYTES)];
    unsigned address = 0;
    if ([[NSScanner scannerWithString:addressBytes] scanHexInt:&address]) {
        return address;
    }
    return 0;
}

- (NSString *)payloadFromLine:(NSString *)line {
    NSString *lengthBytes = [line substringWithRange:NSMakeRange(0, PAGE_INDEX_BYTES)];
    unsigned length = 0;
    if ([[NSScanner scannerWithString:lengthBytes] scanHexInt:&length]) {
        if (line.length > PAGE_PAYLOAD_START_BYTES + length * 2) {
            return [line substringWithRange:NSMakeRange(PAGE_PAYLOAD_START_BYTES, length * 2)];
        }
    }
    return nil;
}

- (int)bytesCount {
    return ROM_END - ROM_START;
}

- (NSData *)blockAtIndex:(UInt16)index /*length:(int *)length */{
    
    if (index < self.blocks.count) {
        ANBlock *block = self.blocks[index];
        return [block getBlock];
    }
    return nil;
}

- (NSData *)dataBlockForIndex:(NSInteger)startIndex length:(NSInteger)length {
    
    int bytesCount = [self bytesCount];
    NSMutableData *dataBlock = [NSMutableData dataWithCapacity:length];
    for (int i = 0; i < length; i++)
    {
        if (startIndex + i < bytesCount)
        {
            [dataBlock appendBytes:&self.bytes[startIndex + i] length:1];
        }
        else
        {
            UInt8 val = 0xFF;
            [dataBlock appendBytes:&val length:1];
        }
    }
    return dataBlock;
}

#pragma mark CRC validation

- (BOOL)validateCRC:(UInt16)crc forBlockAtIndex:(UInt16)blockIndex {
    int length = 0;
    NSData *block = [self blockAtIndex:blockIndex];
    return [self validateCRC:crc forBlock:(uint8_t*)[block bytes] length:length atIndex:blockIndex];
}

- (BOOL)validateTotalCRC:(UInt16)crc {
    return [self validateCRC:crc forBlock:self.bytes length:[self bytesCount] atIndex:0];
}

- (BOOL)validateCRC:(UInt16)crc forBlock:(uint8_t *)block length:(NSInteger)length atIndex:(NSInteger)index {
    NSInteger address = index * PAGE_PAYLOAD_BYTES;
    NSMutableData *data = [NSMutableData data];
    [data appendBytes:&index length:sizeof(index)];
    [data appendBytes:&address  length:sizeof(address)];
    [data appendData:[NSData dataWithBytes:block length:length]];
    uint16_t dataCRC = crc16ccitt((u_int8_t const *)block, (int)length);
    return dataCRC == crc;
}



@end
