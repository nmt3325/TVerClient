#!/usr/bin/env python3
import argparse, datetime as dt, json, os, plistlib, zipfile

def app_info(path):
    with zipfile.ZipFile(path) as z:
        names=[n for n in z.namelist() if n.startswith('Payload/') and n.count('/')==2 and n.endswith('.app/Info.plist')]
        if len(names)!=1: raise SystemExit(f'Expected one application Info.plist, found {len(names)}')
        return plistlib.loads(z.read(names[0]))

def main():
    p=argparse.ArgumentParser(); p.add_argument('--ipa',required=True); p.add_argument('--output',required=True); p.add_argument('--download-url',default='https://github.com/nmt3325/TVerClient/releases/latest/download/TVerClient-unsigned.ipa'); p.add_argument('--date',default=dt.datetime.now(dt.timezone.utc).date().isoformat()); p.add_argument('--commit',default=''); a=p.parse_args(); info=app_info(a.ipa)
    bid=str(info['CFBundleIdentifier']); version=str(info['CFBundleShortVersionString']); build=str(info['CFBundleVersion']); minimum=str(info.get('MinimumOSVersion','16.0'))
    if bid!='dev.nmt3325.TVerClient': raise SystemExit(f'Unexpected bundle identifier: {bid}')
    change='診断ログ書き出し、番組表、見逃し・ライブ再生を含むUnsigned IPAです。'+(f' Build {a.commit[:7]}.' if a.commit else '')
    src={'name':'TVer Client','subtitle':'TVer ClientのAltStore・SideStore・LiveContainer対応ソース','description':'非公式TVer iOSクライアントのUnsigned IPA配布ソースです。','iconURL':'https://nmt3325.github.io/TVerClient/icon.png','website':'https://nmt3325.github.io/TVerClient/','tintColor':'#2589FF','nsfw':False,'featuredApps':[bid],'apps':[{'name':'TVer Client','bundleIdentifier':bid,'developerName':'TVerClient Contributors','subtitle':'番組表・見逃し・ライブ再生に対応した非公式クライアント','localizedDescription':'新聞型番組表、サムネイル、見逃し再生、ライブテレビ、バックグラウンド音声、プライバシー保護付き診断ログを備えます。','iconURL':'https://nmt3325.github.io/TVerClient/icon.png','tintColor':'#2589FF','category':'entertainment','versions':[{'version':version,'buildVersion':build,'date':a.date,'localizedDescription':change,'downloadURL':a.download_url,'size':os.path.getsize(a.ipa),'minOSVersion':minimum}],'appPermissions':{'entitlements':[],'privacy':{}}}],'news':[]}
    os.makedirs(os.path.dirname(os.path.abspath(a.output)),exist_ok=True)
    with open(a.output,'w',encoding='utf-8') as f: json.dump(src,f,ensure_ascii=False,indent=2); f.write('\n')
if __name__=='__main__': main()
