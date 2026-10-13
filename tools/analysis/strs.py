import re,sys
b=open(sys.argv[1],'rb').read()
out=open(sys.argv[2],'w')
for m in re.finditer(rb'[\x20-\x7e]{5,}',b): out.write('A %x %s\n'%(m.start(),m.group().decode()))
for m in re.finditer(rb'(?:[\x20-\x7e]\x00){5,}',b): out.write('W %x %s\n'%(m.start(),m.group().decode('utf-16le')))
