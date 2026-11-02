from PIL import Image, ImageDraw, ImageFont
import os
W,H=1920,1080
OUT=os.path.dirname(os.path.abspath(__file__))
FD=r"C:\Windows\Fonts"
def F(n,s): return ImageFont.truetype(os.path.join(FD,n),s)
T=F("seguisb.ttf",46); ST=F("segoeui.ttf",26); BT=F("seguisb.ttf",27); BL=F("seguisym.ttf",20)
LT=F("seguisym.ttf",20); LS=F("seguisym.ttf",17); NB=F("segoeuib.ttf",20); CAP=F("seguisym.ttf",28)
INK="#201F1E";SUB="#605E5C";LINE="#C8C6C4";RED="#D13438";BLUE="#0078D4";PUR="#8661C5";GRN="#107C10";ORG="#CA5010";GH="#D2D0CE"
BG={"n":"#FFFFFF","r":"#FDE7E9","b":"#EAF3FC","p":"#F3EEFA","g":"#E7F5E6","x":"#F5F4F3"}
BD={"n":"#8A8886","r":RED,"b":BLUE,"p":PUR,"g":GRN,"x":GH}

def box(d,b):
    x0,y0,x1,y1=b["xy"]; s=b.get("s","n")
    d.rounded_rectangle((x0+5,y0+6,x1+5,y1+6),14,fill="#E8E6E4")
    d.rounded_rectangle(b["xy"],14,fill=BG[s],outline=BD[s],width=3)
    tc=GH if s=="x" else INK; lc=GH if s=="x" else SUB
    d.text((x0+20,y0+14),b["t"],font=BT,fill=tc)
    for i,l in enumerate(b.get("l",[])):
        c=lc
        if l.startswith("+"): l="✓ "+l[1:]; c=GH if s=="x" else GRN
        if l.startswith("!"): l="✗ "+l[1:]; c=GH if s=="x" else RED
        d.text((x0+20,y0+56+i*27),l,font=BL,fill=c)

def group(d,xy,t):
    x0,y0,x1,y1=xy
    for x in range(x0,x1,22): d.line((x,y0,min(x+12,x1),y0),fill=LINE,width=2); d.line((x,y1,min(x+12,x1),y1),fill=LINE,width=2)
    for y in range(y0,y1,22): d.line((x0,y,x0,min(y+12,y1)),fill=LINE,width=2); d.line((x1,y,x1,min(y+12,y1)),fill=LINE,width=2)
    w=d.textlength(t,font=LS)
    d.rectangle((x0+16,y0-12,x0+30+w,y0+12),fill="white"); d.text((x0+23,y0-11),t,font=LS,fill=SUB)

def arrow(d,pts,c,w=6,dash=False):
    import math
    for i in range(len(pts)-1):
        (x0,y0),(x1,y1)=pts[i],pts[i+1]
        if i==len(pts)-2:
            L=math.hypot(x1-x0,y1-y0); ux,uy=(x1-x0)/L,(y1-y0)/L; x1e,y1e=x1-ux*20,y1-uy*20
        else: x1e,y1e=x1,y1
        if dash:
            L=math.hypot(x1e-x0,y1e-y0); n=int(L//24)
            for k in range(n+1):
                a=k*24/L; b=min((k*24+14)/L,1)
                d.line((x0+(x1e-x0)*a,y0+(y1e-y0)*a,x0+(x1e-x0)*b,y0+(y1e-y0)*b),fill=c,width=w)
        else: d.line((x0,y0,x1e,y1e),fill=c,width=w)
    (x0,y0),(x1,y1)=pts[-2],pts[-1]; L=math.hypot(x1-x0,y1-y0); ux,uy=(x1-x0)/L,(y1-y0)/L
    d.polygon([(x1,y1),(x1-ux*26-uy*13,y1-uy*26+ux*13),(x1-ux*26+uy*13,y1-uy*26-ux*13)],fill=c)

def label(d,xy,n,t,s,c):
    x,y=xy; w=max(d.textlength(t,font=LT),d.textlength(s,font=LS))+50
    d.rounded_rectangle((x-6,y-6,x+w,y+48),8,fill="white",outline=c,width=2)
    d.ellipse((x,y+4,x+30,y+34),fill=c); d.text((x+15,y+19),n,font=NB,fill="white",anchor="mm")
    d.text((x+40,y-2),t,font=LT,fill=INK); d.text((x+40,y+23),s,font=LS,fill=SUB)

def stamp(d,xy,ok):
    x,y=xy; c=GRN if ok else RED
    d.ellipse((x-26,y-26,x+26,y+26),fill=c,outline="white",width=4)
    d.text((x,y-2),"✔" if ok else "✖",font=F("seguisym.ttf",30),fill="white",anchor="mm")

def frame(spec,k):
    im=Image.new("RGB",(W,H),"white"); d=ImageDraw.Draw(im)
    d.rectangle((40,34,50,130),fill=spec["acc"])
    d.text((72,26),spec["title"],font=T,fill=INK); d.text((72,90),spec["sub"],font=ST,fill=SUB)
    for g in spec.get("groups",[]): group(d,*g)
    for b in spec["boxes"]: box(d,b)
    steps=spec["steps"]
    for i,st in enumerate(steps[:k]):
        for a in st.get("arrows",[]): arrow(d,a[0],a[1],dash=len(a)>2 and a[2])
    for i,st in enumerate(steps[:k]):
        for l in st.get("labels",[]): label(d,*l)
        for s in st.get("stamps",[]): stamp(d,*s)
    cap=steps[k-1].get("cap") if k else spec.get("cap0")
    if cap:
        c=steps[k-1].get("capc",spec["acc"]) if k else spec["acc"]
        d.rounded_rectangle((30,940,1890,1060),14,fill="#F5F4F3"); d.rectangle((30,940,42,1060),fill=c)
        y=958
        for line in cap.split("\n"): d.text((66,y),line,font=CAP if y==958 else ST,fill=INK if y==958 else SUB); y+=46
    return im

def build(name,spec):
    frames=[frame(spec,k) for k in range(len(spec["steps"])+1)]
    bd=os.path.join(OUT,"builds",name); os.makedirs(bd,exist_ok=True)
    for i,f in enumerate(frames): f.save(os.path.join(bd,f"step-{i:02d}.png"))
    frames[-1].save(os.path.join(OUT,name+".png"))
    small=[f.resize((1280,720),Image.LANCZOS) for f in frames]
    pal=small[-1].quantize(256,method=Image.Quantize.MEDIANCUT)
    q=[s.quantize(palette=pal,dither=Image.Dither.NONE) for s in small]
    dur=[1800]*(len(q)-1)+[6000]
    q[0].save(os.path.join(OUT,name+".gif"),save_all=True,append_images=q[1:],duration=dur,loop=0)
    print(name,len(frames),"frames")

# ---------- shared geometry ----------
K=(55,250,420,470); G=(55,640,420,850)
D=(740,210,1120,370); P=(740,440,1120,680); S=(1450,440,1850,680); O=(740,760,1120,900); L=(1450,760,1850,900)
GRPS=[((30,185,450,925),"Molina KMS server · no public IP"),((500,185,1890,925),"Azure · API keys OFF · public network OFF")]

# ---------- 01 problem ----------
problem=dict(acc=RED,title="Today: KMS pushes vectors into AI Search with an API key",
 sub="Works in dev, but can't pass the Security review",
 cap0="KMS does everything itself: chunk → embed → push",
 boxes=[dict(xy=(55,250,420,500),t="KMS server",l=["SQL Server 2022 on a VM","~3,000 articles","→ ~12,000 chunks","700-token chunking"]),
        dict(xy=P,t="API gateway (APIM)",l=["carries embedding calls","Security: OAuth on every call"]),
        dict(xy=O,t="Azure OpenAI",l=["embedding model","3,072 numbers / chunk"]),
        dict(xy=S,t="Azure AI Search",l=["kms index","!accepts API keys today"],s="r")],
 steps=[
  dict(arrows=[([(420,470),(740,470)],SUB),([(930,680),(930,760)],SUB)],labels=[((450,540),"1","embed each chunk","text out · 3,072 numbers back",SUB)],
       cap="1 · KMS sends each chunk to the embedding model through the gateway\n~35 KB of JSON comes back per chunk"),
  dict(arrows=[([(420,300),(1650,300),(1650,440)],ORG)],labels=[((1180,250),"2","push chunks + vectors","API key · ~399 MB per full reindex",ORG)],
       cap="2 · KMS pushes chunks + vectors straight into AI Search with an API key\nThis call goes AROUND the gateway"),
  dict(stamps=[((1650,300),False)],capc=RED,cap="Blocker 1 · the API key\nSecurity requires OAuth through a gateway on every call — a key is a shared secret"),
  dict(arrows=[([(1120,600),(1450,600)],RED,True)],stamps=[((1285,600),False)],labels=[((1150,700),"!","push through the gateway instead?","139,847 B per article → payload failures / throttling",RED)],
       capc=RED,cap="Blocker 2 · the payload\nRoute the push through the gateway and it's too big: ~399 MB per full reindex"),
 ])

# ---------- arch boxes ----------
def arch_boxes(mode):
    gA = "x" if mode=="B" else None
    gB = "x" if mode=="A" else None
    return [dict(xy=K,t="KMS publisher",l=["on the KMS server","+managed identity","app role: KMS.Ingest"],s=gA or "n"),
            dict(xy=G,t="Agent app",l=["support-center, Python","+managed identity","app role: KMS.Search"],s=gB or "n"),
            dict(xy=D,t="ADLS Gen2",l=["article landing zone","+shared key off · private"],s=gA or "b"),
            dict(xy=P,t="API Management",l=["the one gateway","checks token + app role","pins model · token limits"]),
            dict(xy=S,t="Azure AI Search",l=["indexer + built-in skills","vectorizer · semantic ranker","+API keys off"]),
            dict(xy=O,t="Azure OpenAI",l=["text-embedding-3-large","+keys off · private endpoint"],s=gB or "p"),
            dict(xy=L,t="Log Analytics",l=["one audit trail","for all four services"],s="x" if mode!="AB" else "n")]
A1=dict(arrows=[([(420,290),(740,290)],BLUE)],labels=[((450,215),"1","article JSON + chunks","OAuth · private endpoint",BLUE)],cap="1 · KMS drops the article (with its own chunks) into ADLS\nOAuth via managed identity, private endpoint — no key")
A2=dict(arrows=[([(420,420),(740,500)],BLUE)],labels=[((450,380),"2","pointer ~120 B","OAuth (KMS.Ingest)",BLUE)],cap="2 · KMS sends only a ~120-byte pointer through APIM\nAPIM checks the Entra token + KMS.Ingest app role")
A3=dict(arrows=[([(1120,480),(1450,480)],BLUE)],labels=[((1150,395),"3","run indexer","APIM managed identity",BLUE)],cap="3 · APIM tells AI Search to run the indexer — using APIM's own identity")
A4=dict(arrows=[([(1650,440),(1650,290),(1120,290)],BLUE)],labels=[((1300,215),"4","pull articles","Search MI · shared private link",BLUE)],cap="4 · AI Search pulls the files from ADLS privately\nThe heavy data never crosses the gateway")
B5=dict(arrows=[([(1450,560),(1120,560)],PUR)],labels=[((1150,520),"5","embed chunks","Search MI · shared private link",PUR)],capc=PUR,cap="5 · AI Search's built-in embedding skill calls APIM\nManaged-identity token over a shared private link — no custom code")
B6=dict(arrows=[([(930,680),(930,760)],PUR)],labels=[((960,695),"6","pinned deployment","APIM MI · private endpoint",PUR)],capc=PUR,cap="6 · APIM forwards to one pinned embedding model\nSame model at index and query time → vectors can't drift")
Q1=dict(arrows=[([(420,745),(740,640)],PUR)],labels=[((450,700),"Q1","question","OAuth (KMS.Search)",PUR)],capc=PUR,cap="Q1 · The agent asks a question through APIM with its own token + KMS.Search role")
Q2=dict(arrows=[([(1120,640),(1450,640)],PUR)],labels=[((1150,605),"Q2","hybrid + semantic query","published-only guardrail",PUR)],capc=PUR,cap="Q2 · APIM runs hybrid + semantic search — published articles only\nThe vectorizer embeds the question through the same pinned model")
LG=dict(arrows=[([(1650,680),(1650,760)],SUB,True),([(1120,840),(1450,840)],SUB,True)],capc=GRN,cap="Every hop logged in one place: APIM · Search · ADLS · OpenAI")
ARCH=dict(groups=GRPS)
optA=dict(ARCH,acc=BLUE,title="Option A: move the data by pointer",sub="Files land in ADLS; only a small pointer goes through the gateway",
  boxes=arch_boxes("A"),cap0="Option A fixes Blocker 2 (payload) and Blocker 1 for ingestion",
  steps=[A1,A2,A3,A4,dict(stamps=[((420,420),True)],capc=GRN,cap="✓ Blocker 2 fixed: a ~120 B pointer, not 139,847 B\nStill open: who makes the vectors? → Option B")])
optB=dict(ARCH,acc=PUR,title="Option B: AI Search makes the vectors, through APIM",sub="Built-in embedding skill + vectorizer call the gateway — documented, no custom code",
  boxes=arch_boxes("B"),cap0="Option B: KMS stops calling the embedding model itself",
  steps=[B5,B6,Q1,Q2,dict(capc=GRN,cap="✓ Every AI call goes through APIM with a managed-identity token over Private Link\n✓ One pinned model · built-in skill · no keys")])
sol=dict(ARCH,acc=GRN,title="The fix: Option A + Option B together",sub="Same Azure services, wired differently: no keys, pointer through the gateway, vectors made inside Azure",
  boxes=arch_boxes("AB"),cap0="Same Azure services — wired differently",
  steps=[A1,A2,A3,A4,B5,B6,Q1,Q2,LG,dict(capc=GRN,cap="✓ No API keys anywhere  ✓ ~120 B pointer through the gateway  ✓ Private links only\nBlue = Option A (ingest)   ·   Purple = Option B (vectors + query)")])

# ---------- 05 side by side ----------
def side():
    im=Image.new("RGB",(W,H),"white"); d=ImageDraw.Draw(im)
    d.rectangle((40,34,50,130),fill=GRN)
    d.text((72,26),"From blocked to unblocked: same features, new plumbing",font=T,fill=INK)
    d.text((72,90),"Left: today  ·  Right: Option A + B",font=ST,fill=SUB)
    for x0,c,bgc,t in [(40,RED,"#FDE7E9","TODAY · BLOCKED"),(985,GRN,"#E7F5E6","WITH OPTION A + B")]:
        d.rounded_rectangle((x0,160,x0+895,740),18,fill="#FAFAF9",outline=c,width=3)
        d.rounded_rectangle((x0+20,175,x0+40+d.textlength(t,font=LT),210),16,fill=c); d.text((x0+30,178),t,font=LT,fill="white")
    sm=lambda xy,t,s="n":box(d,dict(xy=xy,t=t,s=s))
    sm((70,300,330,380),"KMS"); sm((380,470,640,550),"Gateway"); sm((640,300,900,380),"AI Search","r")
    arrow(d,[(330,340),(640,340)],ORG); stamp(d,(485,340),False); d.text((400,270),"API key + vectors",font=LT,fill=ORG)
    arrow(d,[(200,380),(200,510),(380,510)],RED,dash=True); stamp(d,(290,510),False); d.text((110,560),"too big · throttled",font=LT,fill=RED)
    d.text((70,640),"✗ API key = shared secret",font=LT,fill=RED); d.text((70,680),"✗ 139,847 B per article through gateway fails",font=LT,fill=RED)
    o=985
    sm((o+30,240,o+250,320),"KMS"); sm((o+330,240,o+560,320),"ADLS","b"); sm((o+330,430,o+560,510),"APIM"); sm((o+640,430,o+870,510),"AI Search"); sm((o+330,580,o+560,640),"OpenAI","p")
    arrow(d,[(o+250,280),(o+330,280)],BLUE); arrow(d,[(o+140,320),(o+140,470),(o+330,470)],BLUE)
    arrow(d,[(o+560,450),(o+640,450)],BLUE); arrow(d,[(o+755,430),(o+755,280),(o+560,280)],BLUE)
    arrow(d,[(o+640,495),(o+560,495)],PUR); arrow(d,[(o+445,510),(o+445,580)],PUR)
    d.text((o+150,410),"~120 B",font=LT,fill=BLUE)
    d.text((o+30,660),"✓ OAuth + managed identities, no keys",font=LT,fill=GRN); d.text((o+30,700),"✓ pointer through gateway → 202 Accepted",font=LT,fill=GRN)
    rows=[("","Today","With A + B"),("Credential","API key (shared secret)","Entra ID tokens + managed identities"),
          ("Through the gateway","139,847 B per article: fails","~120 B pointer: 202 Accepted"),("Who makes vectors","KMS code, then a big push","AI Search built-in skill, via APIM")]
    for i,(a,b,c) in enumerate(rows):
        y=770+i*62; f=LT if i==0 else BL
        if i: d.line((40,y-8,1880,y-8),fill="#EDEBE9",width=2)
        d.text((60,y+8),a,font=LT,fill=INK); d.text((420,y+8),b,font=f,fill=RED if i else INK); d.text((1100,y+8),c,font=f,fill=GRN if i else INK)
    d.text((60,1030),"Unchanged for KMS: 700-token chunking · hybrid + BM25 + semantic ranking · Python SDK · LOB / State / Effective Date filters",font=LS,fill=SUB)
    im.save(os.path.join(OUT,"05-problem-vs-solution.png")); print("05 done")

# ---------- 06 payload vs pointer ----------
pay=dict(acc=BLUE,title="The gateway carries a pointer, not the payload",sub="The same article, sent two ways",
 boxes=[dict(xy=(120,330,520,560),t="Payload",l=["139,847 B","1 article · 4 chunks + vectors"],s="r"),
        dict(xy=(120,640,520,800),t="Pointer",l=["123 B · 1,136× smaller"],s="b"),
        dict(xy=(800,330,1100,800),t="API gateway",l=["checks token","+ app role"]),
        dict(xy=(1450,450,1850,560),t="Azure AI Search",l=[]),dict(xy=(1450,680,1850,790),t="ADLS Gen2",l=[],s="b")],
 cap0="Same article, two ways through the gateway",
 steps=[dict(arrows=[([(520,445),(800,445)],ORG)],stamps=[((660,445),False)],labels=[((560,360),"✖","413 payload_too_large","test gateway caps the push at 8 KB",RED)],capc=RED,cap="Payload: too big for the gateway (~399 MB per full reindex)"),
        dict(arrows=[([(520,720),(800,720)],BLUE),([(1100,500),(1450,500)],BLUE)],stamps=[((660,720),True)],labels=[((1150,410),"✔","202 Accepted → run indexer","APIM managed identity",GRN)],capc=GRN,cap="Pointer: 123 B passes → APIM starts the indexer"),
        dict(arrows=[([(1650,680),(1650,560)],BLUE)],labels=[((1680,590),"↑","pull · private link","Search MI",BLUE)],capc=GRN,cap="AI Search pulls the heavy data from ADLS privately\nNo bulk index payload ever crosses the gateway")])

import sys
want=sys.argv[1:]
for n,s in [("01-problem",problem),("02-option-a",optA),("03-option-b",optB),("04-solution-a-plus-b",sol),("06-payload-vs-pointer",pay)]:
    if not want or n[:2] in want: build(n,s)
if not want or "05" in want: side()



