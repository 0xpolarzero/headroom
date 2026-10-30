import json
s=open(__import__('sys').argv[1]).read(); L=json.load(open('logos.json'))
def svg(k,size,fill): l=L[k]; return f'<svg width="{size}" height="{size}" viewBox="{l["viewBox"]}">'+''.join(f'<path d="{d}" fill="{fill}"/>' for d in l['d'])+'</svg>'
v=s.replace('__LOGOS__',json.dumps(L))
v=v.replace('__CLAUDEB__',svg('claude',16,'#E08A68')).replace('__ANTIGRAVITY__',svg('antigravity',18,'#EAF2FA')).replace('__CLAUDE__',svg('claude',18,'#E08A68')).replace('__CODEX__',svg('codex',18,'#EAF2FA')).replace('__ZAI__',svg('zai',18,'#7C9BFF'))
v=v.replace('__CLAUDEW__',svg('claude',20,'#fff')).replace('__CODEXW__',svg('codex',20,'#fff')).replace('__ZAIW__',svg('zai',20,'#fff'))
open(__import__('sys').argv[2],'w').write(v)
