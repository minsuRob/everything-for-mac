# 상주 stdio MCP 클라이언트: python3 -I mcpd.py <workdir>
# <workdir>/req/<id>.json ({"name":..,"args":..})을 읽어 REA MCP 도구를 호출하고 <workdir>/res/<id>.json에 쓴다.
# Ghidra 분석을 한 번만 하고 여러 질의를 돌리기 위해 쓴다(CLI는 호출마다 다시 분석한다).
import json, subprocess, sys, os, time, glob
here=os.path.dirname(os.path.abspath(sys.argv[0])); base=os.path.abspath(sys.argv[1]); req=os.path.join(base,'req'); res=os.path.join(base,'res')
os.makedirs(req,exist_ok=True); os.makedirs(res,exist_ok=True)
p=subprocess.Popen([os.path.join(here,'rea.sh'),'mcp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(os.path.join(base,'server.err'),'w'),text=True,bufsize=1)
nid=[0]
def send(method,params=None,notify=False):
    msg={'jsonrpc':'2.0','method':method}
    if params is not None: msg['params']=params
    if not notify: nid[0]+=1; msg['id']=nid[0]
    p.stdin.write(json.dumps(msg)+'\n'); p.stdin.flush()
    if notify: return None
    while True:
        line=p.stdout.readline()
        if not line: raise SystemExit('server closed')
        try: r=json.loads(line)
        except Exception: continue
        if r.get('id')==nid[0]: return r
send('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'efm-analysis','version':'0'}})
send('notifications/initialized',notify=True)
print('ready',flush=True)
while True:
    for f in sorted(glob.glob(os.path.join(req,'*.json'))):
        cid=os.path.basename(f)[:-5]; c=json.load(open(f)); os.remove(f); t=time.time()
        if c['name']=='__quit__': p.terminate(); sys.exit(0)
        r=send('tools/call',{'name':c['name'],'arguments':c.get('args',{})})
        json.dump(r,open(os.path.join(res,cid+'.tmp'),'w'),ensure_ascii=False,indent=1)
        os.rename(os.path.join(res,cid+'.tmp'),os.path.join(res,cid+'.json'))
        print('%s %s %.1fs %s'%(cid,c['name'],time.time()-t,'ERR' if 'error' in r or r.get('result',{}).get('isError') else 'ok'),flush=True)
    time.sleep(0.3)
