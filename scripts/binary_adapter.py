"""Adapt a supported local copy's loader metadata; never change the supplied IPA."""
import struct

def adapt(raw):
 b=bytearray(raw)
 if len(b)<32:raise ValueError('binary_header')
 magic,cpu,sub,kind,ncmd,size,flags,res=struct.unpack_from('<8I',b)
 if magic!=0xfeedfacf or cpu!=0x100000c or kind!=2 or ncmd>4096 or 32+size>len(b):raise ValueError('binary_header')
 commands=[];off=32;first_section=len(b)
 for _ in range(ncmd):
  if off+8>32+size:raise ValueError('load_commands')
  cmd,cs=struct.unpack_from('<II',b,off)
  if cs<8 or off+cs>32+size:raise ValueError('load_commands')
  c=bytearray(b[off:off+cs]);off+=cs
  if cmd==0x19:
   if cs<72:raise ValueError('segment_header')
   count=struct.unpack_from('<I',c,64)[0]
   if 72+80*count>cs:raise ValueError('section_header')
   for i in range(count):
    section_offset=struct.unpack_from('<I',c,72+i*80+48)[0]
    if section_offset:first_section=min(first_section,section_offset)
  if cmd in (0x21,0x2c):
   if cs<20 or struct.unpack_from('<I',c,16)[0]!=0:raise ValueError('encrypted_binary')
  if cmd in (0x32,0x25,0x24):c=bytearray(struct.pack('<6I',0x32,24,6,0x000e0000,0x001a0000,0))
  if cmd==0x80000028:continue
  if cmd==0x19 and c[8:24].rstrip(b'\0')==b'__PAGEZERO':struct.pack_into('<Q',c,32,0)
  if cmd in (0xc,0x80000018) and b'@rpath/libswift' in c:
   no=struct.unpack_from('<I',c,8)[0];name=bytes(c[no:]).split(b'\0')[0].decode()
   dest=('/System/iOSSupport/usr/lib/swift/' if 'libswiftUIKit' in name else '/usr/lib/swift/')+name.split('/')[-1]
   new=dest.encode()+b'\0';new+=b'\0'*((-len(new))%8);c=c[:24]+new;struct.pack_into('<II',c,4,len(c),24)
  commands.append(c)
 new=b''.join(commands)
 # Never grow into the first section's bytes.
 if 32+max(size,len(new))>first_section:raise ValueError('load_command_capacity')
 b[32:32+max(size,len(new))]=new+b'\0'*max(0,size-len(new));struct.pack_into('<III',b,12,8,len(commands),len(new))
 return bytes(b).replace(b'Localize\0',b'GPCLocal\0').replace(b'Converter\0',b'GPCConvrt\0')
