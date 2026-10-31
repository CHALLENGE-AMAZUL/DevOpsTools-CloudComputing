"""Confere a API; credenciais opcionais ficam em arquivo privado."""
import base64
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

base = sys.argv[1].rstrip('/')
private = {}
if len(sys.argv) > 2:
    private = dict(line.split('=', 1) for line in Path(sys.argv[2]).read_text().splitlines()
                   if line and not line.startswith('#') and '=' in line)

def call(path, method='GET', data=None, auth=False, expected=200):
    headers = {'Content-Type': 'application/json'}
    if auth:
        credentials = private['APP_ADMIN_USERNAME'] + ':' + private['APP_ADMIN_PASSWORD']
        headers['Authorization'] = 'Basic ' + base64.b64encode(credentials.encode()).decode()
    request = urllib.request.Request(base + path, data=None if data is None else json.dumps(data).encode(),
                                     method=method, headers=headers)
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    body = response.read()
    assert response.code == expected, f'{method} {path}: HTTP {response.code}, esperado {expected}'
    content_type = response.headers.get_content_type()
    if not body or not (content_type == 'application/json' or content_type.endswith('+json')):
        return body
    return json.loads(body)

assert call('/actuator/health')['status'] == 'UP'
call('/swagger-ui/index.html')
spec = call('/v3/api-docs')
assert spec['servers'][0]['url'] == '/'
assert '/api/artigos/buscaPorTitulo' in spec['paths']
call('/api/artigos')
call('/api/artigos?pagina=-1', expected=400)
call('/api/artigos', 'POST', {}, expected=401)
if private:
    article = {'titulo': 'Tecnologia nuclear na sociedade', 'resumo': 'Aplicações educativas da tecnologia nuclear.',
               'aplicacaoReal': 'Radioisótopos são utilizados em diagnóstico médico.',
               'impactoSociedade': 'Conhecimento científico acessível à sociedade.', 'area': 'SAUDE'}
    created = call('/api/artigos', 'POST', article, auth=True, expected=201)
    aid = created['id']
    article['area'] = 'PESQUISA'
    assert call(f'/api/artigos/{aid}', 'PUT', article, auth=True)['areaAplicacao'] == 'PESQUISA'
    assert call('/api/artigos/buscaPorTitulo?titulo=Tecnologia')['totalElementos'] >= 1
    call(f'/api/artigos/{aid}', 'DELETE', auth=True, expected=204)
    call(f'/api/artigos/{aid}', expected=404)
    print('Cadastro, atualização, busca e exclusão concluídos.')
print('Health UP, Swagger disponível e escrita protegida em', base)
