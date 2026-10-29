#!/usr/bin/env python3
"""Export one Mihomo VLESS/REALITY TCP node as a URI and optional QR code."""
import argparse
import os
from pathlib import Path
import re
import sys
from urllib.parse import quote, urlencode
from uuid import UUID


def make_uri(node):
    if node.get('type') != 'vless' or node.get('network', 'tcp') != 'tcp':
        raise ValueError('仅支持 VLESS + REALITY + TCP 节点')
    reality = node.get('reality-opts')
    if node.get('tls') is not True or not isinstance(reality, dict):
        raise ValueError('节点必须开启 TLS 并配置 reality-opts')
    for field in ('server', 'uuid', 'servername'):
        if not isinstance(node.get(field), str) or not node[field].strip():
            raise ValueError(f'节点缺少有效的 {field}')
    UUID(node['uuid'])
    port = node.get('port')
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('port 必须为 1–65535 的整数')
    public_key = reality.get('public-key', '')
    if not isinstance(public_key, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', public_key):
        raise ValueError('public-key 必须为 43 字符的 X25519 公钥')
    sid = reality.get('short-id', '')
    if not isinstance(sid, str) or not re.fullmatch(r'(?:[0-9a-fA-F]{2}){0,8}', sid):
        raise ValueError('short-id 必须为最多 16 位的偶数长度十六进制字符串；请在 YAML 中加引号')
    flow = node.get('flow', '')
    if flow not in ('', 'xtls-rprx-vision'):
        raise ValueError('不支持的 flow')
    host = node['server']
    if any(c in host for c in '/?#@[]') or any(c.isspace() for c in host):
        raise ValueError('server 必须为不含 URL 路径的域名或 IP（IPv6 无需方括号）')
    host = f'[{host}]' if ':' in host else host.encode('idna').decode('ascii')
    params = dict(encryption='none', security='reality', type='tcp',
                  sni=node['servername'], fp=node.get('client-fingerprint', 'chrome'),
                  pbk=public_key, sid=sid)
    if flow:
        params['flow'] = flow
    return f"vless://{quote(node['uuid'], safe='')}@{host}:{port}?{urlencode(params, quote_via=quote)}#{quote(str(node.get('name', 'VPS')), safe='')}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', nargs='?', default='client.yaml')
    parser.add_argument('--name', help='选择 proxies 中的节点名称；有多个节点时必填')
    parser.add_argument('--output', default='shadowrocket.txt', help='链接输出路径')
    parser.add_argument('--qr', metavar='PNG', help='同时生成本地二维码 PNG')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        import yaml
    except ImportError:
        parser.error('缺少 PyYAML，请运行：python3 -m pip install -r requirements-shadowrocket.txt')
    try:
        config = yaml.safe_load(Path(args.config).read_text())
        nodes = config.get('proxies', []) if isinstance(config, dict) else []
        nodes = [n for n in nodes if isinstance(n, dict) and n.get('type') == 'vless'
                 and (args.name is None or n.get('name') == args.name)]
        if len(nodes) != 1:
            raise ValueError('需要唯一的 VLESS 节点；请检查配置或用 --name 指定节点')
        uri = make_uri(nodes[0])
        output = Path(args.output)
        paths = [Path(args.config).resolve(), output.resolve()]
        if args.qr:
            paths.append(Path(args.qr).resolve())
        if len(set(paths)) != len(paths):
            raise ValueError('输入配置、链接、二维码必须使用不同路径')
        for target in [output] + ([Path(args.qr)] if args.qr else []):
            if target.exists() or target.is_symlink():
                raise FileExistsError(17, '输出文件已存在', str(target))
        qr = None
        if args.qr:
            try:
                import qrcode
            except ImportError:
                raise ValueError('缺少 qrcode，请安装 requirements-shadowrocket.txt') from None
            qr = qrcode.make(uri)
        # Exclusive creation avoids overwriting existing files or following symlinks.
        with output.open('x', encoding='utf-8') as handle:
            handle.write(uri + '\n')
        print(f'已生成链接：{output}')
        if qr is not None:
            with Path(args.qr).open('xb') as handle:
                qr.save(handle, format='PNG')
            print(f'已生成二维码：{args.qr}')
        if nodes[0]['reality-opts'].get('support-x25519mlkem768'):
            print('提示：Mihomo 的 support-x25519mlkem768 不转换为链接参数；实际握手取决于小火箭版本。', file=sys.stderr)
    except yaml.YAMLError as exc:
        # Do not print parser diagnostics: they can contain credentials.
        mark = getattr(exc, 'problem_mark', None)
        location = f'（第 {mark.line + 1} 行，第 {mark.column + 1} 列）' if mark else ''
        print(f'转换失败：YAML 格式错误{location}，请检查缩进及引号。', file=sys.stderr)
        return 1
    except FileExistsError as exc:
        print(f'转换失败：输出文件已存在：{exc.filename}。请移走旧文件，或用 --output 和 --qr 指定新路径。', file=sys.stderr)
        return 1
    except OSError as exc:
        print(f'转换失败：无法访问文件 {exc.filename}（{exc.strerror}）。', file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f'转换失败：{exc}', file=sys.stderr)
        return 1
    except TypeError:
        print('转换失败：节点字段类型错误，请检查 YAML 中的字符串、整数和布尔值。', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
