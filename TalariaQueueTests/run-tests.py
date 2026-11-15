#!/usr/bin/env python3
"""Run isolated iOS ChatModel tests without changing the shared Xcode project.

Requires xcodegen, PyYAML, aiohttp and an iOS 27 simulator. Example:
  <python-with-aiohttp> TalariaQueueTests/run-tests.py --sim <simulator UUID>
"""
import argparse
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import yaml

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sim', required=True)
parser.add_argument('--filter', default='ChatQueueTests')
parser.add_argument('--ui', action='store_true', help='Run the real navigation UI regression')
parser.add_argument('--artifacts', type=Path, help='Reuse a scratch project/build for fast subsequent runs')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
scratch = args.artifacts or Path(tempfile.mkdtemp(prefix='talaria-queue-', dir=os.environ['TMPDIR']))
scratch.mkdir(parents=True, exist_ok=True)
run_id = time.time_ns()
spec = yaml.safe_load((root / 'project.yml').read_text())
# A project generated outside the checkout must keep build-setting paths absolute.
for target in spec['targets'].values():
    settings = target.get('settings', {}).get('base', {})
    for key in ('INFOPLIST_FILE', 'CODE_SIGN_ENTITLEMENTS'):
        if key in settings:
            settings[key] = str(root / settings[key])
    if 'entitlements' in target:
        target['entitlements']['path'] = str(root / target['entitlements']['path'])
spec['targets']['TalariaQueueTests'] = {
    'type':'bundle.unit-test', 'platform':'iOS',
    'sources':[{'path':'TalariaQueueTests/ChatQueueTests.swift'}],
    'dependencies':[{'target':'Talaria'}, {'package':'HermesKit','product':'HermesKit'}],
    'settings':{'base':{'GENERATE_INFOPLIST_FILE':'YES',
                        'PRODUCT_BUNDLE_IDENTIFIER':'com.example.talaria.queuetests',
                        'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Talaria.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Talaria',
                        'BUNDLE_LOADER':'$(TEST_HOST)'}}}
spec['schemes']['Queue'] = {
    'build':{'targets':{'Talaria':'all','TalariaQueueTests':['test']}},
    'test':{'config':'Debug','targets':['TalariaQueueTests'],
            'environmentVariables':{'TALARIA_SERVER':'http://127.0.0.1:19129',
                                    'TALARIA_SIGNIN_FILE':'/fixture/no-signin.json',
                                    'TALARIA_REMEMBER_SIGNIN_FILE':'0', 'TALARIA_OPEN_CHAT':''}}}
if args.ui:
    spec['schemes']['Queue']['build']['targets']['TalariaUITests'] = ['test']
    spec['schemes']['Queue']['test']['targets'] = ['TalariaUITests']
    spec['schemes']['Queue']['test']['environmentVariables']['TALARIA_QUEUE_SHOTS'] = str(scratch / 'shots')
(scratch / 'project.yml').write_text(yaml.safe_dump(spec))
subprocess.run(['xcodegen','generate','--spec',str(scratch/'project.yml'),
                '--project',str(scratch),'--project-root',str(root)],check=True)
# Never silently test against another fixture (or a real service) already using this port.
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    probe.bind(('127.0.0.1', 19129))
fixture_log = (scratch/f'fixture-{run_id}.log').open('w')
fixture = subprocess.Popen([sys.executable,str(root/'TalariaQueueTests/gateway_fixture.py')],
                           stdout=fixture_log,stderr=subprocess.STDOUT)
try:
    for _ in range(100):
        if fixture.poll() is not None:
            raise RuntimeError('fixture exited before becoming ready')
        try:
            urllib.request.urlopen('http://127.0.0.1:19129/__metrics',timeout=.2).read()
            break
        except OSError:
            time.sleep(.05)
    else:
        raise RuntimeError('fixture did not start')
    subprocess.run(['xcrun','simctl','boot',args.sim],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    print('QUEUE_TEST_ARTIFACTS',scratch,flush=True)
    target = 'TalariaUITests/QueueNavigationTests' if args.ui else 'TalariaQueueTests/' + args.filter
    result = subprocess.run(['xcodebuild','-project',str(scratch/'Talaria.xcodeproj'),'-scheme','Queue',
        '-destination',f'platform=iOS Simulator,id={args.sim}', '-derivedDataPath',str(scratch/'build'),
        '-resultBundlePath',str(scratch/f'result-{run_id}.xcresult'),'-only-testing:'+target,
        '-parallel-testing-enabled','NO','-test-timeouts-enabled','YES',
        '-maximum-test-execution-time-allowance','120' if args.ui else '30',
        'CODE_SIGNING_ALLOWED=NO','test'],stdout=(scratch/'xcodebuild.log').open('w'),stderr=subprocess.STDOUT)
    log = (scratch/'xcodebuild.log').read_text()
    (scratch/f'xcodebuild-{run_id}.log').write_text(log)
    for line in log.splitlines():
        if any(token in line for token in ['error:', 'failed', 'passed', 'OPENING ', 'Executed ', '** TEST']):
            print(line)
    print('FULL_LOG',scratch/'xcodebuild.log',flush=True)
    if result.returncode == 0 and not re.search(r'Executed [1-9]\d* tests?', log):
        raise RuntimeError('xcodebuild ran zero tests; check --filter rather than accepting a false green')
    sys.exit(result.returncode)
finally:
    try:
        (scratch/f'fixture-metrics-{run_id}.json').write_bytes(
            urllib.request.urlopen('http://127.0.0.1:19129/__metrics',timeout=1).read())
    except OSError:
        pass
    fixture.terminate()
    try:
        fixture.wait(timeout=5)
    except subprocess.TimeoutExpired:
        fixture.kill()
        fixture.wait()
    fixture_log.close()