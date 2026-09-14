#!/usr/bin/env python3
"""Render 4.8-second EN/KO promos from real Damson captures. Requires Pillow/ffmpeg.
Screenshots show a deliberately staged demo workspace, not live AI agent output.
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from pathlib import Path
import math, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
W,H,FPS,FRAMES=1280,800,30,144
font_path='/System/Library/Fonts/AppleSDGothicNeo.ttc'
def font(size): return ImageFont.truetype(font_path,size,index=6)
base=Image.new('RGB',(W,H)); pix=base.load()
for y in range(H):
 for x in range(W):
  p=math.exp(-((x-1070)**2+(y-100)**2)/260000)
  q=math.exp(-((x-180)**2+(y-740)**2)/190000)
  pix[x,y]=(int(13+38*p),int(14+17*p+16*q),int(25+65*p+20*q))
shots={name:Image.open(ROOT/'assets/screenshots'/name).convert('RGB').crop((0,0,1800,820)) for name in ['native-en.png','native-ko.png','split-workspace.png']}
strings={
 'en':('One terminal. Your whole crew.', ['Native macOS. Swift + Metal.', 'Split the work. Keep the context.', 'Built for your AI coding workflow.'], 'Make something worth sharing.', 'Actual app capture · Demo workspace'),
 'ko':('터미널 하나로, 함께 만드는 흐름.', ['Mac을 위해 만든 Swift + Metal 터미널', '작업은 나누고, 맥락은 한눈에.', 'AI 코딩 작업을 한곳에서.'], '멋진 결과물을 만들고 공유하세요.', '실제 앱 화면 · 촬영용 작업 공간')}
def scene(lang,t):
 im=base.copy(); d=ImageDraw.Draw(im)
 title,subs,cta,note=strings[lang]
 d.ellipse((68,35,82,49),fill='#b49bff');d.text((96,25),'DAMSON',font=font(23),fill='#e6dcff')
 d.text((1020,28),'macOS ONLY',font=font(18),fill='#b3a6ce')
 d.text((66,81),title,font=font(62 if lang=='en' else 60),fill='#f5f1ff')
 stage=0 if t<1.45 else (1 if t<3.1 else 2)
 d.text((70,165),subs[stage],font=font(29),fill='#b9add2')
 src=shots['native-'+lang+'.png'] if stage==0 else shots['split-workspace.png']
 # Subtle camera lift, with pixels always sourced from the actual capture.
 local=t-[0,1.45,3.1][stage]
 lift=int(4*math.sin(min(local,1.2)/1.2*math.pi/2))
 x,y,w,h=70,224-lift,1140,519
 shadow=Image.new('RGBA',(W,H));sd=ImageDraw.Draw(shadow)
 sd.rounded_rectangle((x-3,y+12,x+w+3,y+h+15),radius=22,fill=(0,0,0,160))
 im=Image.alpha_composite(im.convert('RGBA'),shadow.filter(ImageFilter.GaussianBlur(18)))
 card=src.resize((w,h),Image.Resampling.LANCZOS)
 mask=Image.new('L',(w,h));ImageDraw.Draw(mask).rounded_rectangle((0,0,w-1,h-1),radius=18,fill=255)
 im.paste(card,(x,y),mask)
 d=ImageDraw.Draw(im);d.rounded_rectangle((x,y,x+w,y+h),radius=18,outline='#5d5575',width=1)
 d.text((72,757),'damson.app',font=font(22),fill='#c8b4ff')
 d.text((250,761),note,font=font(15),fill='#958ba7')
 textw=d.textbbox((0,0),cta,font=font(19))[2];d.text((1208-textw,759),cta,font=font(19),fill='#d8d1e7')
 return im.convert('RGB')
for lang in strings:
 with tempfile.TemporaryDirectory(prefix='damson-promo-') as tmp:
  first=scene(lang,0)
  for n in range(FRAMES):
   t=n/FPS; im=scene(lang,t)
   # Return to the opening frame for a smooth infinite loop.
   if t>=4.4: im=Image.blend(im,first,min(1,(t-4.4)/(.4-1/FPS)))
   im.save(f'{tmp}/{n:03}.png')
  mp4=ROOT/'assets'/f'damson-promo-{lang}.mp4'
  subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-framerate',str(FPS),'-i',f'{tmp}/%03d.png','-frames:v',str(FRAMES),'-c:v','libx264','-crf','19','-pix_fmt','yuv420p','-movflags','+faststart',str(mp4)],check=True)
  subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(mp4),'-filter_complex','fps=20,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192[p];[b][p]paletteuse=dither=bayer:bayer_scale=4','-loop','0',str(ROOT/'assets'/f'damson-promo-{lang}.gif')],check=True)
  first.save(ROOT/'assets'/f'damson-promo-{lang}-poster.png')
