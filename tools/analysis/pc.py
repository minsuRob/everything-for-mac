import json,sys
r=json.load(open(sys.argv[1]));t=''.join(c.get('text','') for c in r['result']['content']); d=json.loads(t)
nr=d['normalized_result']; open(sys.argv[2],'w').write(nr if isinstance(nr,str) else json.dumps(nr,indent=1))
