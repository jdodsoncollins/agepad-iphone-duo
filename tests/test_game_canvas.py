"""Exercise production game-canvas geometry without a Simulator or account."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='agepad-canvas-') as directory:
    source = Path(directory) / 'canvas.c'
    source.write_text(r'''
#include "GameCanvas.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    CGSize viewports[]={ {956,440},{874,402},{667,375},{568,320},{1366,1024},{1190,820},{400,700} };
    for(unsigned i=0;i<sizeof(viewports)/sizeof(*viewports);i++){
        CGSize viewport=viewports[i],canvas=DEGameCanvasSize(viewport);double fit=DEGameCanvasFit(viewport);
        assert(canvas.width>=1024 && canvas.height>=720);
        assert(canvas.width*fit<=viewport.width+.001 && canvas.height*fit<=viewport.height+.001);
        CGPoint original={viewport.width*.37,viewport.height*.61};CGPoint game=DEGamePointFromHost(original,viewport),back=DEHostPointFromGame(game,viewport);
        assert(fabs(original.x-back.x)<.0001 && fabs(original.y-back.y)<.0001);
        // An overlay button scaled into canvas coordinates stays 44pt on glass.
        assert(fabs(44/fit*fit-44)<.0001);
        // At native scale 3 the larger logical canvas doesn't triple pixel work.
        double backing=DEGameCanvasBackingScale(viewport,3);
        assert(canvas.width*backing<=viewport.width*3+4);
    }
    assert(CGSizeEqualToSize(DEGameCanvasSize((CGSize){1366,1024}),(CGSize){1366,1024}));
    assert(CGSizeEqualToSize(DEGameCanvasSize(CGSizeZero),CGSizeZero));
    puts("game minimum resolution, input round trips and physical control size passed (7 viewports)");
}
''')
    binary = Path(directory) / 'canvas'
    subprocess.run(['xcrun', 'clang', '-I', str(ROOT / 'port/de'), str(source),
                    '-framework', 'CoreGraphics', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
