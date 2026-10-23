# Noria turbine geometry, shared with App/DesignSystem/TurbineView.swift.
# Usage: python3 Tools/generate_icon.py [output-appiconset-dir]   (requires Pillow)
import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

def hexc(h): h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))
DEEP,PRIMARY,BRIGHT,SKY=map(hexc,["075B9A","087BC1","00A9E8","73DDF3"])

def polar(r,deg):
    a=math.radians(deg); return (r*math.cos(a), r*math.sin(a))
def cubic(p0,c1,c2,p1,n=40):
    pts=[]
    for i in range(n+1):
        t=i/n; u=1-t
        pts.append((u**3*p0[0]+3*u*u*t*c1[0]+3*u*t*t*c2[0]+t**3*p1[0], u**3*p0[1]+3*u*u*t*c1[1]+3*u*t*t*c2[1]+t**3*p1[1]))
    return pts

# Blade in local frame (degrees). Shared with TurbineGeometry.swift.
BLADE = dict(base0=(0.28,-12), c1=(0.72,-42), c2=(1.12,38), tip=(0.93,100),
             c3=(0.66,96), c4=(0.46,62), base1=(0.28,46))

def blade(rot):
    b={k:polar(v[0],v[1]+rot) for k,v in BLADE.items()}
    return cubic(b['base0'],b['c1'],b['c2'],b['tip'])+cubic(b['tip'],b['c3'],b['c4'],b['base1'])

def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3))
def grad(stops,t):
    for i in range(len(stops)-1):
        t0,c0=stops[i]; t1,c1=stops[i+1]
        if t<=t1: return lerp(c0,c1,(t-t0)/(t1-t0) if t1>t0 else 0)
    return stops[-1][1]

def render(size, bg=None, icon=False, ss=4):
    S=size*ss
    img=Image.new('RGBA',(S,S),(0,0,0,0))
    scale = S*0.5*(0.78 if icon else 0.98); cx=cy=S/2
    tr=lambda p:(cx+p[0]*scale, cy+p[1]*scale)
    gap=max(2,int(scale*0.045))
    for i in range(5):
        rot=i*72-90
        pts=[tr(p) for p in blade(rot)]
        # gradient fill: along blade from base (bright/sky) to tip (deep)
        mask=Image.new('L',(S,S),0); ImageDraw.Draw(mask).polygon(pts,fill=255)
        tip=tr(polar(0.96,62+rot)); base=tr(polar(0.32,25+rot))
        g=Image.new('RGBA',(S,S))
        # build linear gradient quickly via small image then resize-rotate is complex; do per-row approx using projection
        dx,dy=tip[0]-base[0],tip[1]-base[1]; L2=dx*dx+dy*dy
        xs,ys=zip(*pts); x0,x1,y0,y1=int(min(xs)),int(max(xs))+1,int(min(ys)),int(max(ys))+1
        px=g.load()
        stops=[(0,SKY),(0.35,BRIGHT),(0.7,PRIMARY),(1,DEEP)]
        for y in range(max(0,y0),min(S,y1)):
            for x in range(max(0,x0),min(S,x1),1):
                t=((x-base[0])*dx+(y-base[1])*dy)/L2; t=min(1,max(0,t))
                c=grad(stops,t); px[x,y]=c+(255,)
        # cut gap along leading (outer) edge of this blade on what is already drawn
        cut=Image.new('L',(S,S),0)
        b={k:polar(v[0],v[1]+rot) for k,v in BLADE.items()}
        edge=[tr(p) for p in cubic(b['base0'],b['c1'],b['c2'],b['tip'])]
        ImageDraw.Draw(cut).line(edge,fill=255,width=gap*2,joint='curve')
        ImageDraw.Draw(cut).polygon(pts,fill=255)
        a=img.getchannel('A'); a=ImageChops.subtract(a,cut); img.putalpha(a)
        img=Image.composite(g,img,mask)
    # hub ring gap + hub
    d=ImageDraw.Draw(img)
    r_cut=0.27*scale
    cut=Image.new('L',(S,S),0); ImageDraw.Draw(cut).ellipse([cx-r_cut,cy-r_cut,cx+r_cut,cy+r_cut],fill=255)
    a=img.getchannel('A'); img.putalpha(ImageChops.subtract(a,cut))
    rh=0.17*scale
    hub=Image.new('RGBA',(S,S)); hp=hub.load()
    for y in range(int(cy-rh),int(cy+rh)+1):
        for x in range(int(cx-rh),int(cx+rh)+1):
            dd=math.hypot(x-cx+rh*0.3,y-cy+rh*0.3)/(rh*1.6)
            hp[x,y]=grad([(0,SKY),(0.5,BRIGHT),(1,PRIMARY)],min(1,dd))+(255,)
    hm=Image.new('L',(S,S),0); ImageDraw.Draw(hm).ellipse([cx-rh,cy-rh,cx+rh,cy+rh],fill=255)
    img=Image.composite(hub,img,hm)
    if icon:
        base=Image.new('RGBA',(S,S),(0,0,0,0))
        m=int(S*0.09); rad=int(S*0.18)
        sh=Image.new('RGBA',(S,S),(0,0,0,0)); ImageDraw.Draw(sh).rounded_rectangle([m,m+S*0.01,S-m,S-m+S*0.01],rad,fill=(10,40,70,90)); sh=sh.filter(ImageFilter.GaussianBlur(S*0.012))
        base=Image.alpha_composite(base,sh)
        tile=Image.new('RGBA',(S,S),(0,0,0,0)); tp=ImageDraw.Draw(tile)
        tp.rounded_rectangle([m,m,S-m,S-m],rad,fill=(255,255,255,255))
        # subtle vertical gradient
        grad_img=Image.new('RGBA',(S,S)); gd=ImageDraw.Draw(grad_img)
        for y in range(S): v=int(255-(y/S)*14); gd.line([(0,y),(S,y)],fill=(v,v+0 if v<255 else 255,min(255,v+2),255))
        tm=Image.new('L',(S,S),0); ImageDraw.Draw(tm).rounded_rectangle([m,m,S-m,S-m],rad,fill=255)
        base=Image.composite(grad_img,base,tm)
        img_s=img.resize((int(S*0.80),int(S*0.80)),Image.LANCZOS)
        off=(S-img_s.size[0])//2
        layer=Image.new('RGBA',(S,S),(0,0,0,0)); layer.paste(img_s,(off,off),img_s)
        img=Image.alpha_composite(base,layer)
    if bg:
        b=Image.new('RGBA',(S,S),bg+(255,)); img=Image.alpha_composite(b,img)
    return img.resize((size,size),Image.LANCZOS)

if __name__=='__main__':
    # PROVISIONAL app icon generator. Replace the PNGs in
    # App/Resources/Assets.xcassets/AppIcon.appiconset with the final artwork
    # (same file names) — no code changes are needed.
    import os, json
    out=sys.argv[1] if len(sys.argv)>1 else 'App/Resources/Assets.xcassets/AppIcon.appiconset'
    os.makedirs(out,exist_ok=True)
    big=render(1024,icon=True,ss=2)
    images=[]
    for pt in [16,32,128,256,512]:
        for scale in [1,2]:
            px=pt*scale; name=f'icon_{pt}x{pt}@{scale}x.png'
            big.resize((px,px),Image.LANCZOS).save(os.path.join(out,name))
            images.append({"idiom":"mac","scale":f"{scale}x","size":f"{pt}x{pt}","filename":name})
    json.dump({"images":images,"info":{"author":"xcode","version":1}},open(os.path.join(out,'Contents.json'),'w'),indent=2)
