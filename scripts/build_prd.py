"""Build the current PRD with reportlab and pypdf; run from any directory on macOS."""
from pathlib import Path
from html import escape
from reportlab.pdfgen import canvas
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak, KeepTogether, Flowable
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.enums import TA_LEFT
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs'
OUT.mkdir(parents=True, exist_ok=True)
FONT = Path('/System/Library/Fonts/Supplemental')
for name, filename in [('Body','Arial.ttf'),('Bold','Arial Bold.ttf'),('Italic','Arial Italic.ttf')]:
    pdfmetrics.registerFont(TTFont(name, str(FONT/filename)))
pdfmetrics.registerFontFamily('Body', normal='Body', bold='Bold', italic='Italic', boldItalic='Bold')

NAVY = colors.HexColor('#142F43')
TEAL = colors.HexColor('#087E83')
INK = colors.HexColor('#263B49')
MUTED = colors.HexColor('#607381')
PALE = colors.HexColor('#EEF5F6')
LINE = colors.HexColor('#D7E2E7')
WHITE = colors.white
W,H = (595.2756,841.8898)
WIDTH = W-92

styles = {
 'body': ParagraphStyle('body',fontName='Body',fontSize=10.1,leading=14.3,textColor=INK,spaceAfter=8),
 'small': ParagraphStyle('small',fontName='Body',fontSize=8.7,leading=12.0,textColor=MUTED,spaceAfter=5),
 'tiny': ParagraphStyle('tiny',fontName='Body',fontSize=8.0,leading=10.7,textColor=INK,spaceAfter=4),
 'h1': ParagraphStyle('h1',fontName='Bold',fontSize=25,leading=29,textColor=NAVY,spaceAfter=12),
 'hero': ParagraphStyle('hero',fontName='Bold',fontSize=42,leading=45,textColor=NAVY,spaceAfter=16),
 'h2': ParagraphStyle('h2',fontName='Bold',fontSize=13.0,leading=17,textColor=NAVY,spaceBefore=12,spaceAfter=7),
 'h3': ParagraphStyle('h3',fontName='Bold',fontSize=10.7,leading=14,textColor=NAVY,spaceBefore=7,spaceAfter=5),
 'eyebrow': ParagraphStyle('eyebrow',fontName='Bold',fontSize=9,leading=12,textColor=TEAL,spaceAfter=10),
 'intro': ParagraphStyle('intro',fontName='Body',fontSize=13.0,leading=18.5,textColor=INK,spaceAfter=14),
 'story': ParagraphStyle('story',fontName='Body',fontSize=9.4,leading=12.8,textColor=INK,spaceAfter=5),
 'ac': ParagraphStyle('ac',fontName='Body',fontSize=9.0,leading=12.3,textColor=INK,leftIndent=12,firstLineIndent=-12,spaceAfter=3),
 'th': ParagraphStyle('th',fontName='Bold',fontSize=9,leading=12,textColor=WHITE),
 'td': ParagraphStyle('td',fontName='Body',fontSize=9,leading=12.3,textColor=INK),
}

def p(text, style='body'):
    # Prohibit dash glyphs the PDF workflow explicitly asks us to avoid.
    assert not any(ch in text for ch in '\u2010\u2011\u2012\u2013\u2014'), text
    return Paragraph(text,styles[style])

def label(text): return p(text.upper(),'eyebrow')
def h(text): return p(text,'h2')
def bullet(text): return p('- '+text,'body')

def callout(title,text):
    t=Table([[p(title,'h3')],[p(text,'body')]],colWidths=[WIDTH-24])
    t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),PALE),('BOX',(0,0),(-1,-1),0.4,LINE),
       ('LEFTPADDING',(0,0),(-1,-1),12),('RIGHTPADDING',(0,0),(-1,-1),12),
       ('TOPPADDING',(0,0),(-1,0),4),('BOTTOMPADDING',(0,-1),(-1,-1),8)]))
    return t

def table(headers, rows, widths=None):
    widths=widths or [WIDTH/len(headers)]*len(headers)
    data=[[p(x,'th') for x in headers]]+[[p(x,'td') for x in row] for row in rows]
    t=Table(data,colWidths=widths,repeatRows=1,hAlign='LEFT')
    t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),NAVY),('ROWBACKGROUNDS',(0,1),(-1,-1),[WHITE,PALE]),
      ('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),9),('RIGHTPADDING',(0,0),(-1,-1),9),
      ('TOPPADDING',(0,0),(-1,-1),8),('BOTTOMPADDING',(0,0),(-1,-1),8),('LINEBELOW',(0,-1),(-1,-1),0.5,LINE)]))
    return t

def section(kicker,title,intro=None):
    items=[label(kicker),p(title,'h1')]
    if intro: items.append(p(intro,'intro'))
    return items

class FlowStrip(Flowable):
    def __init__(self,items):
        Flowable.__init__(self)
        self.items=items;self.width=WIDTH;self.height=72
    def draw(self):
        c=self.canv; n=len(self.items); gap=14; bw=(WIDTH-gap*(n-1))/n
        for i,(a,b) in enumerate(self.items):
            x=i*(bw+gap)
            c.setFillColor(PALE);c.roundRect(x,8,bw,58,5,fill=1,stroke=0)
            c.setFillColor(TEAL);c.setFont('Bold',9);c.drawString(x+10,48,a)
            c.setFillColor(INK);c.setFont('Body',8.5)
            for j,line in enumerate(b.split('|')):c.drawString(x+10,32-j*12,line)
            if i<n-1:
                c.setStrokeColor(TEAL);c.line(x+bw+3,36,x+bw+11,36)
                c.line(x+bw+8,39,x+bw+11,36);c.line(x+bw+8,33,x+bw+11,36)

class PortfolioDoc(SimpleDocTemplate):
    def __init__(self,path,title,short,total):
        self.doc_title=title;self.short=short;self.total=total
        super().__init__(str(path),pagesize=(W,H),leftMargin=46,rightMargin=46,topMargin=68,bottomMargin=54,
                         title=title,author='Nikhil Sharma',subject='Nik\'s Photo Viewer product management portfolio',creator='Created with assistance from Codex')
    def paint(self,c,doc):
        c.saveState()
        c.setFillColor(TEAL);c.rect(0,H-7,W,7,fill=1,stroke=0)
        c.setFont('Bold',9);c.setFillColor(NAVY);c.drawString(46,H-35,"NIK'S PHOTO VIEWER")
        c.setFont('Body',8.3);c.setFillColor(MUTED);c.drawRightString(W-46,H-35,self.short)
        c.setStrokeColor(LINE);c.line(46,40,W-46,40)
        c.setFont('Body',8);c.setFillColor(MUTED)
        c.drawString(46,26,'Nikhil Sharma  |  Product management portfolio  |  13 October 2026')
        c.drawRightString(W-46,26,f'{doc.page} / {self.total}')
        c.restoreState()

def build(name,title,short,pages):
    story=[]
    for i,items in enumerate(pages):
        if i:story.append(PageBreak())
        story.extend(items)
    target=OUT/name
    doc=PortfolioDoc(target,title,short,len(pages))
    doc.build(story,onFirstPage=doc.paint,onLaterPages=doc.paint)
    reader=PdfReader(target)
    assert len(reader.pages)==len(pages),(name,len(reader.pages),len(pages))
    print(f'{target}: {len(reader.pages)} pages, {target.stat().st_size:,} bytes')
    return target


def prd_pages():
    pages = []
    pages.append([
      Spacer(1, 15), label('Product requirements document / current contract'),
      p("Nik's Photo<br/>Viewer", 'hero'),
      p('A focused, read-only image browser for the Mac.', 'intro'),
      callout('Product owner: Nikhil Sharma',
        "Nikhil defines the problem, scope, interaction details and release decisions. Codex, OpenAI's AI coding assistant, assists with implementation, investigation, testing and documentation."),
      h('Product thesis'),
      p('Open a photo, inspect detail, and move through its folder with minimal friction. No importing, editing tools, multiple photo windows or persistent photo library.'),
      h('What changed on 13 October 2026'),
      bullet('Up/Down arrow zoom with smooth transitions, alongside the existing slider and buttons.'),
      bullet("A new name, Nik's Photo Viewer, placed next to the window controls, plus a colourful original icon."),
      bullet('No Hide command or Window menu in the app menu bar. Standard window controls remain.'),
      h('Status and scope'),
      p('Source is publicly published under MIT at github.com/nikhilrsharma/photo-viewer-macos. This document updates the existing retrospective PRD with the current requirements and the October 13 implementation. The repository name and bundle identifier stay stable.'),
      p('Target: Apple silicon, macOS 26+. Local development: Xcode 27 / Swift 6.4. The 11 October delivery backlog remains a historical snapshot; this PRD and current security documentation supersede conflicting claims.', 'small'),
      p('This document is reconstructed from the product conversation and implementation. It does not imply that formal research or a PRD existed before the first prototype.', 'small')
    ])
    pages.append(section('01 / strategy and product journey', 'Less friction, not more features',
      'Primary user: a Mac owner browsing images directly from Finder.') + [
      h('Jobs to be done'),
      bullet('Open the selected image large, without entering full-screen mode or creating another photo window.'),
      bullet('Browse mixed image formats in a predictable order and know the current file and position.'),
      bullet('Inspect detail using the keyboard, mouse or trackpad while preserving the original.'),
      table(['User signal', 'Decision', 'PM rationale'], [
       ['Navigation failed; duplicate app entries', 'Reliable key routing and folder permissions; avoid duplicate installations', 'Make the central browsing journey dependable'],
       ['Zoom percentage moved or looked attached to +', 'Compact percentage over the slider thumb; aligned min/max captions', 'Make scale understandable without extra text'],
       ['Unclear whether Fit was enabled', 'Selected Fit button; explicit manual state', 'State must be visible and reversible'],
       ['Could Rust help? Will caching grow?', 'Retain Swift; cache folder order; downsample; bound RAM cache', 'Improve measured costs before adding language complexity'],
       ['Keyboard zoom; clearer personal identity', 'Up/Down steps, animated scale, stable titlebar name and new icon', 'Reduce pointer movement and improve recognition'],
       ['Do not publish private information', 'Source allowlist, privacy checks, public creator name and noreply commits', 'Separate public attribution from private credentials'],
      ], [139,196,WIDTH-335]),
      h('Non-goals'),
      p('Editing, saving, renaming, deletion, rotation, annotations, thumbnails, slideshows, animation playback, camera RAW, accounts, analytics, cloud-library integration and iOS support. No App Store release or Intel support is claimed.'),
      p('Evidence comes from one product owner\'s feedback and engineering checks, not market research, an adoption study or a statistically validated usability experiment.', 'small')
    ])
    pages.append(section('02 / functional requirements', 'The viewing contract',
      'P0 is essential viewing and trust; P1 is clarity, efficiency or delivery quality.') + [
      table(['ID', 'Requirement', 'Acceptance boundary'], [
       ['R1 / P0', 'One reusable Finder/drop photo window', 'New external opens replace context and reset Fit; multiple selected URLs resolve to one supported image'],
       ['R2 / P0', 'Large, freely resizable normal window', 'About 90% usable display initially; restore saved size; traffic lights; no full-screen mode'],
       ['R3 / P0', 'Left/Right sibling navigation', 'Natural filename order, no wrapping, immediate parent only; preserve zoom mode'],
       ['R4 / P0', 'Mixed native image formats', 'JPEG/JPG, PNG, HEIC/HEIF, TIFF, GIF, BMP, WebP and additional recognised ImageIO formats; actual decoding depends on OS codec and file'],
       ['R5 / P0', 'Fit and manual zoom', '20-200% manual targets in 5% steps; Fit may fall outside those bounds; 100% is one image pixel per screen pixel'],
       ['R6 / P1', 'Compact file context', 'Filename and full path in line 1; creation date, size and Photo x of y in line 2'],
       ['R7 / P0', 'Read-only handling and recovery', 'No image editing operations; errors keep navigation available; first animation frame only'],
       ['R8 / P1', 'Responsive bounded work', 'Background indexing and decoding; one active decode plus latest pending; 128 MiB RAM-only revisit cache'],
       ['R9 / P1', 'About and attribution', 'Nikhil Sharma, Codex credit, recorded build date; no visible version number'],
       ['R10 / P1', 'Open-source delivery', 'MIT, public source, build instructions, privacy review, tests and GitHub checks'],
       ['R11 / P1', 'Keyboard zoom', 'Up increases and Down decreases; repeat supported; text editing and modified keys reserved'],
       ['R12 / P1', 'Name and menu refinement', "Nik's Photo Viewer beside traffic lights; no Hide command or Window menu"],
       ['R13 / P1', 'Colourful app icon', 'Consistent Dock/Finder/About artwork with all standard macOS sizes'],
      ], [61,182,WIDTH-243]),
      p('Filesystem creation date is not EXIF capture time. File size is logical bytes. Missing metadata is labelled unavailable; values are never invented.', 'small')
    ])
    pages.append(section('03 / zoom interaction', 'Keyboard-first inspection',
      'Add keyboard control without changing the existing zoom range or image-browsing keys.') + [
      table(['Action', 'Result'], [
       ['Up / Down', 'Enter manual mode and adjust the current snapped value by +5 / -5 percentage points; clamp to 20-200%'],
       ['Hold Up / Down', 'Use system key repeat; retarget from the current rendered scale; no queued visual jumps'],
       ['Left / Right', 'Previous / next supported sibling; unchanged order and endpoints'],
       ['Slider or - / +', 'Same manual zoom policy as before, now with animated image transitions'],
       ['Fit', 'Return to window-fitting scale; active treatment indicates Fit is on'],
       ['Resize or move to another display', 'Cancel an obsolete transition and calculate correct new geometry and backing scale'],
       ['Text editing or modifier keys', 'Do not hijack editable text arrows or Command/Control/Option/Shift combinations'],
       ['No image', 'Keyboard zoom is a no-op'],
      ], [151,WIDTH-151]),
      h('Smoothness is an interaction requirement'),
      p('Interpolate the displayed image scale over about 140 ms with ease-out timing. Each accepted key repeat updates the target, starting from the currently rendered scale rather than restarting from an old zoom value. Draw the existing decoded image during animation; do not decode for every frame.'),
      p('Preserve the viewed image point near the viewport centre while scaling, subject to scroll boundaries. New images cancel the prior transition. macOS Reduce Motion makes scale changes immediate. Exact frame rate depends on device load; no universal frame-rate guarantee is claimed.'),
      h('Numbers and Fit boundary cases'),
      p('The percentage label and slider indicate the selected target during the short transition. From Fit, controls use the existing nearest 5% manual value before stepping. For example, Fit at about 68% steps up to 75%; below-range Fit at 12% steps up from the clamped 20% position to 25%. Fit itself is not capped.'),
      p('Manual targets remain exact 5% values. Smooth rendering may pass through intermediate scales between targets; this is visual interpolation, not additional selectable zoom settings.', 'small')
    ])
    pages.append(section('04 / identity and acceptance stories', 'Make the app recognisable',
      'The photo remains central; branding stays in the titlebar, menu, About panel and icon.') + [
      h('Identity and menu contract'),
      bullet("Use the exact display name Nik's Photo Viewer, with no version suffix."),
      bullet('Keep the name immediately to the right of the standard red/yellow/green window controls, left-aligned and independent of the image filename.'),
      bullet('App menu contains About and Quit. Remove Hide and the Window menu. Preserve close/minimize/zoom traffic lights and Command-W / Command-M shortcuts.'),
      p('macOS itself may still expose system-level hiding actions (for example in the Dock or application switcher). Removing the app menu command is not a system-wide prohibition on hiding.', 'small'),
      table(['Story', 'Acceptance criteria'], [
       ['S27 / Keyboard zoom', 'Given an open image at 100%, Up selects 105% and Down returns to 100%. Repeats work; endpoints never exceed 20-200%; Left/Right still navigate.'],
       ['S28 / Smooth transitions', 'Retarget without jumping; finish at the requested scale; new images cancel old transitions; Reduce Motion avoids animation.'],
       ['S29 / Titlebar identity', 'Name stays beside traffic lights when opening a different image or resizing. No duplicate centred filename or visible version.'],
       ['S30 / Minimal menus', 'No Hide command, Command-H menu equivalent, or Window menu. About/Quit and standard window controls still work.'],
       ['S31 / Icon', 'Colourful mountain/sun photo tile is legible at Dock sizes; transparent outer corners; no embedded text, private photos or third-party logos.'],
       ['S32 / Delivery', 'Updated PRD, buildable source and tested Release bundle; public commit uses noreply identity; GitHub checks reviewed separately.'],
      ], [127,WIDTH-127]),
      p('S27-S32 extend the older backlog without rewriting its historical story IDs. The icon was generated with the built-in image tool; prompt and source asset are recorded in the repository.', 'small')
    ])
    pages.append(section('05 / trust and resource boundaries', 'Read-only by design',
      'The earlier unsandboxed prototype has been replaced by the hardened source architecture.') + [
      h('Permissions and folder access'),
      p('App Sandbox permits user-selected read-only files and read-only app-scoped folder bookmarks. No network or user-selected write entitlement is present. When sibling access is missing, ask for the exact parent folder. Cancel preserves the current image; reopening can retry. Retain at most 32 approved-folder bookmarks.'),
      h('Hostile or unsuitable input'),
      p('Reject non-local or malformed file URLs, NUL-containing paths and non-regular files before image decoding. Pin a read-only descriptor, use bounded reads, detect source changes and validate cache entries against target identity and precise timestamps.'),
      table(['Resource policy', 'Limit'], [
       ['Source file', '512 MiB'],
       ['Original dimensions', '100,000 px per edge and 100 million pixels total'],
       ['Fit preview', '8,192 px maximum long edge'],
       ['Decoded buffer', '512 MiB estimated before and validated after decoding'],
       ['Revisit cache', '128 MiB decoded bytes, RAM-only'],
      ], [237,WIDTH-237]),
      h('What these protections do not promise'),
      p('ImageIO still parses in process, including metadata. An active synchronous decode cannot be forcibly cancelled. Limits do not cap total process memory or all native codec allocations, and passing tests or CodeQL is not proof of vulnerability freedom. Keep macOS patched.'),
      p('The app never intentionally rewrites photo contents, names or metadata. A prior Finder/LaunchServices smoke test left bytes and creation/modification dates unchanged, but macOS added a last-used extended attribute. Read-only app access does not freeze all operating-system bookkeeping.'),
      p('The image cache disappears on exit; window preferences and folder bookmarks persist. No telemetry, personal photo corpus, account secrets or Apple signing credentials belong in the public source.', 'small')
    ])
    pages.append(section('06 / architecture and evidence', 'Measure the right things',
      'Keep native SwiftUI, AppKit and ImageIO; avoid extra runtime dependencies.') + [
      table(['Component', 'Responsibility'], [
       ['ApplicationState', 'Single image/folder context, zoom target, asynchronous loading and permission state'],
       ['NavigationWindow', 'Route unmodified arrows without stealing editable text; preserve close/minimize shortcuts'],
       ['ViewerScrollView', 'Pixel-correct geometry, centre-preserving pan/zoom and short retargetable animation'],
       ['ImagePipeline / catalog', 'Latest-request decoding, bounded revisit cache, asynchronous natural-sorted folder index'],
       ['App identity / assets', 'Stable display name, left titlebar accessory, minimal menus and macOS icon sizes'],
      ], [160,WIDTH-160]),
      h('Verification for this change'),
      p('The local expanded suite passed 85 tests with zero failures on 13 October 2026. New coverage checks vertical-arrow routing and repeat, reserved modifiers/text editing, titlebar identity, menu contents, interpolation, animation completion/cancellation, Reduce Motion and no-image behaviour. Existing navigation, decoder, permission and zoom-limit tests remain.'),
      h('Historical evidence - not a current speed claim'),
      p('The saved pre-hardening synthetic 48 MP JPEG comparison measured 385.16 ms full-detail median decode versus 273.39 ms Fit-sized decode, and 192.0 MB versus 19.66 MB decoded pixels. Seven warm-cache samples were used. These stage measurements do not establish present whole-app speed, peak RAM or keyboard animation latency.'),
      h('GitHub verification boundary'),
      p('The previous published revision, cc756f3, passed both Build and test and CodeQL. Each new source update requires its own completed checks; earlier green runs are not evidence for a newer commit. The CodeQL-only build-script sandbox override does not disable the app sandbox or hardened runtime.'),
      h('Next measurements'),
      p('On representative, consented local fixtures, measure cold/warm open and key-to-display latency, p50/p95 navigation, frame pacing under repeated zoom and peak resident memory. No adoption, satisfaction, latency SLO or universal performance-improvement percentage is claimed.')
    ])
    pages.append(section('07 / delivery and ownership', 'A maintainable personal product',
      'Public source and a locally built application are distinct deliverables.') + [
      h('Release acceptance checklist'),
      bullet('Run the full automated suite and Release build; verify arm64, sandbox/read-only entitlements, hardened runtime and absence of coverage instrumentation.'),
      bullet('Smoke-test Finder opening, arrow navigation, repeated keyboard zoom, Fit recovery, titlebar placement, menu removal and the new icon in the running app.'),
      bullet('Inspect the final PDF pages and source diff, including asset metadata and commit identity. Do not publish private paths, fixture photos, logs, keys or credentials.'),
      bullet('Publish to the existing repository without changing its identity, MIT license or approved public creator attribution. Review the new GitHub build/security results.'),
      h('Delivery constraints'),
      p('Keep bundle identifier com.nikhilsharma.PhotoViewer stable so existing preferences, folder grants and Finder identity are preserved. Ship one installed application rather than leaving old and new app copies registered. Repository and Xcode target names may remain photo-viewer-macos / PhotoViewer; user-facing names change.'),
      p('Local builds are ad-hoc signed. A generally trusted downloadable binary still requires Developer ID signing, Apple notarisation and clean-install Gatekeeper testing. No Apple account or signing credential is included in this source.'),
      h('Public project'),
      p('<link href="https://github.com/nikhilrsharma/photo-viewer-macos" color="#087E83">github.com/nikhilrsharma/photo-viewer-macos</link><br/>MIT license. Product owner: Nikhil Sharma. AI implementation assistance: Codex.'),
      h('Portfolio framing'),
      callout('Nikhil\'s role',
        'I led a personal macOS utility from a narrowly scoped viewing problem through usability refinement, performance work, security hardening and open-source publication. I used AI for implementation support while retaining ownership of product decisions, trade-offs and acceptance.'),
      p('Basis: the product conversation, current source and test suite, saved synthetic benchmarks, public workflow results, and security documentation. The original 11 October backlog is retained as historical context, not the current release status.', 'small')
    ])
    return pages

if __name__ == '__main__':
    build('Photo-Viewer-PRD.pdf', "Nik's Photo Viewer - Product Requirements Document",
          'PRD / CURRENT CONTRACT', prd_pages())

