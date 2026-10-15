from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
player = (ROOT / 'components/PlayerView.brs').read_text(encoding='utf-8')
parser = (ROOT / 'components/tasks/SubtitleTask.brs').read_text(encoding='utf-8')
def routine(source, name):
    return re.search(r'(?ims)^(?:sub|function) ' + name + r'\(.*?^end (?:sub|function)', source).group()

with tempfile.TemporaryDirectory(prefix='caption-tests-') as tmp:
    script = Path(tmp) / 'test.brs'
    # The off-device interpreter lacks Tokenize; Split covers these fixtures.
    script.write_text('''sub main()
    m.failures = 0
    m.capBox = {visible: false}
    m.capLabel = {text: "", boundingRect: TestRect}
    m.capBg = {}
    m.overlay = {visible: false}
    m.video = {position: 2, state: "playing"}
    m.subOffset = 0
    m.cues = [{s: 1, e: 4, text: "Hello"}]
    m.curCueText = ""
    onCapTick()
    check(m.capBox.visible, "active cue visible")
    m.overlay.visible = true
    onCapTick()
    check(not m.capBox.visible, "menu hides cue")
    m.overlay.visible = false
    onCapTick()
    check(m.capBox.visible, "same cue returns after menu closes")
    m.video.position = 5
    onCapTick()
    check(not m.capBox.visible, "cue expires")
    m.video.position = 2
    onCapTick()
    check(m.capBox.visible, "seek back restores cue")
    m.activeSubtitle = -1
    m.subtitles = []
    m.subTask = {cues: [{s: 1, e: 4, text: "Late"}]}
    m.capTimer = {control: "stop"}
    m.cues = []
    onSubCues()
    check(m.cues.Count() = 0, "late task cannot enable captions after Off")
    for each stamp in ["00:00:01.000 --> 00:00:03.000", "00:00:01,000 --> 00:00:03,000", "00:01.000 --> 00:03.000"]
        cues = ST_ParseCues(stamp + chr(10) + "Hello")
        check(cues.Count() = 1, "VTT/SRT cue parsed")
        if cues.Count() = 1 then check(cues[0].s = 1 and cues[0].e = 3, "cue timing")
    end for
    print "FAILURES: "; m.failures
end sub
sub check(ok as Boolean, label as String)
    if not ok then
        m.failures = m.failures + 1
        print "FAIL: "; label
    end if
end sub
function TestRect() as Object
    return {width: 200, height: 40}
end function
function U_Trim(s as String) as String
    return s.Trim()
end function
function U_StripTags(s as String) as String
    return CreateObject("roRegex", "<[^>]+>", "").ReplaceAll(s, "")
end function
''' + '\n'.join(routine(player, n) for n in ['onCapTick', 'onSubCues']) + '\n' + parser[parser.index('function ST_ParseCues'):].replace('.Tokenize(Chr(10))', '.Split(Chr(10))'), encoding='utf-8')
    result = subprocess.run(['npx.cmd', '--yes', '--package', 'brs@0.45.0', 'brs', str(script)], cwd=ROOT, capture_output=True, text=True)
    print(result.stdout, result.stderr)
    passed = result.returncode == 0 and 'FAILURES:  0' in result.stdout

xml = ET.parse(ROOT / 'components/PlayerView.xml').getroot()
slot = xml.find(".//Group[@id='optionsPanel']")
layout_ok = slot is not None and all(slot.find("Group[@id='" + name + "']") is not None for name in ['qualityPanel', 'ccPanel', 'ccStylePanel', 'audioPanel'])
print('Options share one layout slot:', layout_ok)
raise SystemExit(0 if passed and layout_ok else 1)
