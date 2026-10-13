import json,sys
def load(f):
    r=json.load(open(f)); res=r.get('result',r.get('error'))
    if isinstance(res,dict) and 'content' in res:
        t=''.join(c.get('text','') for c in res['content'])
        try: res=json.loads(t)
        except Exception: return t
    return res.get('normalized_result',res) if isinstance(res,dict) and 'normalized_result' in res else res
for f in sys.argv[1:]:
    nr=load(f); print('==',f)
    if isinstance(nr,dict) and 'references' in nr and 'matches' in nr:
        for m in nr['matches']: print(' M',m.get('type'),m.get('address'),m.get('value'))
        for x in nr['references']:
            cp=(x.get('containing_procedure') or {}).get('procedure') or {}
            print(' R',x.get('target_address'),'<-',x.get('source_address'),'in',cp.get('name'),cp.get('body',{}).get('total_bytes'))
    elif isinstance(nr,dict) and ('pseudo_code' in nr or 'code' in nr or 'pseudocode' in nr):
        print(nr.get('pseudo_code') or nr.get('code') or nr.get('pseudocode'))
    else:
        s=json.dumps(nr,ensure_ascii=False); print(s[:3000])
