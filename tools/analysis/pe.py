import struct, sys
def rd(b,o,f): return struct.unpack_from(f,b,o)
for path in sys.argv[1:]:
    b=open(path,'rb').read()
    pe=rd(b,0x3c,'<I')[0]; mach,nsec=rd(b,pe+4,'<HH'); ts=rd(b,pe+8,'<I')[0]
    optsz=rd(b,pe+20,'<H')[0]; opt=pe+24; magic=rd(b,opt,'<H')[0]
    print('==',path,'machine=%x nsec=%d ts=%d magic=%x'%(mach,nsec,ts,magic))
    sec=opt+optsz; secs=[]
    for i in range(nsec):
        name=b[sec+i*40:sec+i*40+8].rstrip(b'\0').decode(); vs,va,rs,ro=rd(b,sec+i*40+8,'<IIII')
        secs.append((name,va,vs,ro,rs)); print('  sec %-8s va=%x vs=%x raw=%x'%(name,va,vs,rs))
    def r2o(rva):
        for n,va,vs,ro,rs in secs:
            if va<=rva<va+max(vs,rs): return rva-va+ro
    ddir=opt+112
    imp_rva=rd(b,ddir+8,'<I')[0]
    o=r2o(imp_rva); dlls={}
    while True:
        oft,_,_,nm,ft=rd(b,o,'<IIIII')
        if nm==0: break
        dll=b[r2o(nm):].split(b'\0')[0].decode(); names=[]
        t=r2o(oft or ft)
        while True:
            v=rd(b,t,'<Q')[0]
            if v==0: break
            names.append('#%d'%(v&0xffff) if v>>63 else b[r2o(v&0x7fffffff)+2:].split(b'\0')[0].decode())
            t+=8
        dlls[dll]=names; o+=20
    for d,n in dlls.items(): print('  %s (%d): %s'%(d,len(n),' '.join(n)))
