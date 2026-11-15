#!/usr/bin/env python3
"""Local-only HTTP/WebSocket fixture for the real ChatModel opening tests."""
import asyncio
import json
import time
from aiohttp import web

config = {}
calls = []
resumed = False
started = time.monotonic()
sockets = {}
next_socket = 0
stored_tail = []
admissions = {}
receipts = {}
active_admission = 'original-turn'
active_generation = 1


def receipt_for(admission):
    receipt = receipts[admission]
    text = admissions[admission].get('text', '')
    status = config.get('receipt_statuses', {}).get(text)
    if status is not None:
        receipt.update(status=status, outcome=config.get('receipt_outcome', 'completed'))
    return dict(receipt)


async def publish(frame):
    for ws, (_, following) in list(sockets.items()):
        if following and not ws.closed:
            await ws.send_json(frame)


def log(method, **fields):
    entry = dict(method=method, at=time.monotonic()-started, **fields)
    calls.append(entry)
    print(json.dumps(entry), flush=True)


async def control(request):
    global config, calls, started, resumed, stored_tail, admissions, receipts, active_admission, active_generation
    config = await request.json()
    calls = []
    resumed = False
    stored_tail = []
    admissions = {}
    receipts = {}
    active_admission = 'original-turn'
    active_generation = 1
    started = time.monotonic()
    return web.json_response({})


async def configure(request):
    config.update(await request.json())
    return web.json_response({})


async def metrics(request):
    return web.json_response({'calls': calls, 'receipts': receipts,
                              'followers': [n for _, (n, following) in sockets.items() if following]})


async def emit(request):
    global stored_tail, active_admission, active_generation
    body = await request.json()
    if 'messages' in body:
        stored_tail = body['messages']
    for frame in body.get('frames', []):
        event = frame.get('params', {})
        admission = event.get('admission_id')
        event.setdefault('authority_epoch', 1)
        if event.get('type') == 'message.start':
            if admission != active_admission:
                active_generation += 1
            active_admission = admission
            config['gateway_running'] = True
            if admission in receipts:
                receipts[admission].update(status='started', outcome=None, execution_generation=active_generation)
        elif event.get('type') == 'message.complete':
            if admission in receipts:
                payload = event.get('payload', {})
                outcome = 'interrupted' if payload.get('status') == 'interrupted' else payload.get('outcome', 'completed')
                receipts[admission].update(status='terminal', outcome=outcome)
            if admission == active_admission:
                config['gateway_running'] = False
        payload = event.get('payload', {})
        queued_cancel = event.get('type') == 'message.complete' and payload.get('outcome') == 'cancelled' and payload.get('status') != 'interrupted'
        if not queued_cancel:
            event.setdefault('execution_generation', active_generation)
        await publish(frame)
    log('fixture.emit', frames=len(body.get('frames', [])), events=body.get('frames', []))
    return web.json_response({})


async def disconnect(request):
    for ws in list(sockets):
        await ws.close()
    return web.json_response({})


async def websocket(request):
    global next_socket
    ws = web.WebSocketResponse(protocols=['hermes-gateway-v1'])
    await ws.prepare(request)
    next_socket += 1
    number = next_socket
    sockets[ws] = (number, False)
    log('fixture.socket', socket=number)
    await ws.send_json({'jsonrpc':'2.0','method':'event','params':{'type':'gateway.ready','payload':{}}})
    tasks = []

    async def reply(frame):
        global resumed, stored_tail
        method, params = frame['method'], frame.get('params', {})
        profile = params.get('profile', '')
        log(method, profile=profile, params=params, socket=number)
        if method == 'profiles.list':
            result = {'profiles':[{'name':p,'model':'fixture'} for p in ['default','selected','unrelated']]}
        elif method == 'session.active_list':
            await asyncio.sleep(config.get('unrelated_delay', 0) if profile != 'selected' else config.get('active_delay', 0))
            if config.get('active_error') and profile == 'selected':
                await ws.send_json({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32603,'message':'fixture roster unavailable'}})
                return
            sessions = []
            if (config.get('gateway_running') or 'active_status' in config) and profile == 'selected':
                sessions = [{'id':'fixture','session_key':'fixture','status':config.get('active_status', 'working')}]
            result = {'sessions':sessions}
        elif method == 'prompt.submit':
            while params.get('text') in config.get('hold_submissions', []):
                await asyncio.sleep(.01)
            await asyncio.sleep(config.get('submit_delay', 0))
            if config.get('submit_error'):
                await ws.send_json({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32000,'message':'queue_full','data':{'reason':'queue_full'}}})
                return
            admission = 'admitted-' + params.get('submission_id', '')
            if admission in admissions and admissions[admission] != params:
                await ws.send_json({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32000,'message':'admission_conflict','data':{'reason':'admission_conflict'}}})
                return
            if admission not in admissions:
                admissions[admission] = params
                receipts[admission] = {
                    'admission_id': admission, 'ref': {'profile_id': profile, 'session_id': params['session_id']},
                    'sequence': len(admissions), 'status': 'queued', 'outcome': None,
                    'authority_epoch': 1, 'execution_generation': None}
                log('fixture.committed', admission_id=admission)
            if config.get('submit_commit_disconnect'):
                await ws.close()
                return
            if config.get('submit_commit_error'):
                await ws.send_json({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32603,'message':'fixture internal error after commit'}})
                return
            result = receipt_for(admission)
        elif method == 'file.attach':
            suffix = str(sum(c['method'] == method for c in calls)) if config.get('dynamic_attachment_paths') else ''
            path = f'/fixture/example{suffix}.txt'
            result = {'attached': True, 'ref_text': '@file:' + path, 'path': path}
        elif method == 'image.attach_bytes':
            await asyncio.sleep(config.get('attach_delay', 0))
            suffix = str(sum(c['method'] == method for c in calls)) if config.get('dynamic_attachment_paths') else ''
            result = {'attached': True, 'path': f'/fixture/example{suffix}.jpg', 'mime': 'image/jpeg'}
        elif method == 'prompt.receipt':
            if config.get('receipt_error'):
                await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': -32603, 'message': 'receipt unavailable'}})
                return
            admission = params['admission_id']
            result = receipt_for(admission)
        elif method == 'prompt.cancel':
            await asyncio.sleep(config.get('cancel_delay', 0))
            if config.get('cancel_error'):
                await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': -32603, 'message': 'cancel unavailable'}})
                return
            admission = params['admission_id']
            result = receipt_for(admission)
            if result['status'] == 'queued':
                receipts[admission].update(status='terminal', outcome='cancelled')
                result = dict(receipts[admission])
                await publish({'jsonrpc': '2.0', 'method': 'event', 'params': {
                    'type': 'message.complete', 'session_id': params['session_id'],
                    'authority_epoch': 1, 'admission_id': admission,
                    'payload': {'text': '', 'content': '', 'admission_id': admission, 'outcome': 'cancelled'}}})
            log('fixture.cancelled', admission_id=admission, receipt=result)
        elif method == 'session.interrupt':
            # Interrupt is execution-scoped: queued admissions remain runnable until cancelled.
            config['gateway_running'] = False
            if active_admission in receipts:
                receipts[active_admission].update(status='terminal', outcome='interrupted')
            await publish({'jsonrpc': '2.0', 'method': 'event', 'params': {
                'type': 'message.complete', 'session_id': params['session_id'],
                'authority_epoch': 1, 'execution_generation': active_generation,
                'admission_id': active_admission,
                'payload': {'text': '', 'content': '', 'admission_id': active_admission, 'outcome': 'cancelled', 'status': 'interrupted'}}})
            result = {'interrupted': True}
        elif method == 'session.resume':
            await asyncio.sleep(config.get('resume_delay', 0))
            if config.get('resume_error'):
                await ws.send_json({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32603,'message':'fixture resume failed'}})
                return
            resumed = True
            sockets[ws] = (number, True)
            result = {'session_id':'fixture','subscription_id':'fixture-sub','running':config.get('gateway_running',False),'messages':[],'info':{}}
            result.update(authority_epoch=1, execution_generation=active_generation)
            result['prompts'] = config.get('prompts', [])
            if config.get('replay_events'):
                result.update(replay_epoch='fixture-epoch', execution_generation=1)
            if config.get('emit_on_resume'):
                stored_tail = config.get('resume_messages', [])
                for pushed in config['emit_on_resume']:
                    await ws.send_json(pushed)
        elif method == 'session.events.since':
            result = {'events':config.get('replay_events', [])}
        elif method == 'session.detach':
            sockets[ws] = (number, False)
            result = {}
        else:
            result = {}
        await ws.send_json({'jsonrpc':'2.0','id':frame['id'],'result':result})

    async for message in ws:
        if message.type == web.WSMsgType.TEXT:
            for line in message.data.splitlines():
                tasks.append(asyncio.create_task(reply(json.loads(line))))
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    sockets.pop(ws, None)
    return ws


async def http(request):
    path = request.path
    log(path)
    if path == '/api/status':
        result = {'version':'fixture','auth_required':not config.get('open_gate', False),'auth_providers':['nous']}
    elif path == '/api/profiles/sessions/sidebar':
        result = {'recents': {'sessions': [
            {'id':'fixture','title':'Queue navigation fixture','profile':'selected','source':'gui',
             'created_source':'desktop','message_count':2, 'last_active':time.time()}]}}
    elif path == '/api/sessions':
        result = {'total':1,'sessions':[]}
    elif path == '/api/sessions/fixture/messages':
        after_resume = resumed
        tail = list(stored_tail)
        await asyncio.sleep(config.get('final_history_delay', 0) if after_resume else config.get('history_delay', 0))
        if after_resume and config.get('final_history_error'):
            return web.json_response({'error':'fixture history failed'}, status=500)
        messages = [{'id':1,'role':'user','content':'Fixture question'}, {'id':2,'role':'assistant','content':'Fixture answer'}]
        if config.get('commentary_tools'):
            messages += [
                {'id':3,'role':'user','content':'Inspect next change'},
                {'id':4,'role':'assistant','content':'Inspecting the file', 'tool_calls':[
                    {'id':'fixture-tool','function':{'name':'read_file','arguments':{'path':'fixture.swift'}}}]},
                {'id':5,'role':'tool','tool_call_id':'fixture-tool','content':'Fixture file'}]
        if after_resume and config.get('append_after_resume'):
            messages += [{'id':6,'role':'user','content':'Arrived during attachment'},
                         {'id':7,'role':'assistant','content':'Fresh reconciled answer'}]
        messages += tail
        result = {'messages':messages}
    elif path == '/api/sessions/fixture':
        await asyncio.sleep(config.get('row_delay',0))
        result = {'id':'fixture','title':'Queue navigation fixture','profile':'selected'}
        if config.get('external_running') or config.get('fresh_heartbeat'):
            result = dict(result, last_activity_description='Running fixture', last_activity_at=time.time(),
                          source='gui', created_source='desktop')
    else:
        result = {}
    return web.json_response(result)


app = web.Application()
app.router.add_post('/__control',control)
app.router.add_post('/__configure',configure)
app.router.add_get('/__metrics',metrics)
app.router.add_post('/__emit',emit)
app.router.add_post('/__disconnect',disconnect)
app.router.add_get('/api/ws',websocket)
app.router.add_route('*','/{path:.*}',http)
if __name__ == '__main__':
    web.run_app(app,host='127.0.0.1',port=19129)