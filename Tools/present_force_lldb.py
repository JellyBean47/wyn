#!/usr/bin/env python3
"""lldb batch helper: force Wine NSWindows opaque / clear per-pixel alpha."""
import lldb
import sys

def _cmd(debugger, cmd):
    res = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(cmd, res)
    out = res.GetOutput() or ""
    err = res.GetError() or ""
    if out:
        print(out, end="")
    if err:
        print(err, end="", file=sys.stderr)
    return res.Succeeded()

def force(debugger, command, result, internal_dict):
    # Import AppKit into the expression context
    _cmd(debugger, "expr -l objc -- @import AppKit")
    _cmd(debugger, "expr -l objc -- @import QuartzCore")
    src = r'''
@import AppKit;
@import QuartzCore;
@import ObjectiveC;
int n = 0;
for (NSWindow *w in [NSApp windows]) {
  NSString *cls = NSStringFromClass([w class]);
  NSRect f = [w frame];
  BOOL opaque = [w isOpaque];
  CGFloat alpha = [w alphaValue];
  id per = nil;
  if ([w respondsToSelector:@selector(usePerPixelAlpha)]) {
    per = [w valueForKey:@"usePerPixelAlpha"];
  }
  NSView *cv = [w contentView];
  id contents = cv.layer.contents;
  NSLog(@"[present-force] BEFORE class=%@ frame=%@ opaque=%d alpha=%g usePerPixelAlpha=%@ contents=%@ title=%@",
        cls, NSStringFromRect(f), opaque, alpha, per, contents, [w title]);
  if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)]) {
    [w setValue:@NO forKey:@"usePerPixelAlpha"];
  }
  if ([cv respondsToSelector:@selector(setShapeImage:)]) {
    [cv performSelector:@selector(setShapeImage:) withObject:nil];
  }
  if ([w respondsToSelector:@selector(checkTransparency)]) {
    [w performSelector:@selector(checkTransparency)];
  }
  [w setOpaque:YES];
  [w setBackgroundColor:[NSColor windowBackgroundColor]];
  cv.layer.opaque = YES;
  [cv setNeedsDisplay:YES];
  [w displayIfNeeded];
  opaque = [w isOpaque];
  if ([w respondsToSelector:@selector(usePerPixelAlpha)]) {
    per = [w valueForKey:@"usePerPixelAlpha"];
  }
  contents = cv.layer.contents;
  NSLog(@"[present-force] AFTER  class=%@ opaque=%d usePerPixelAlpha=%@ contents=%@",
        cls, opaque, per, contents);
  n++;
}
NSLog(@"[present-force] touched %d windows", n);
n;
'''
    # Write to temp and evaluate via expr -l objc -- with multiline is painful;
    # use one-liner loop instead.
    oneliner = (
        "int n=0; for (NSWindow *w in [NSApp windows]) {"
        " NSLog(@\"[pf] BEFORE %@ opaque=%d alpha=%g title=%@\","
        "  NSStringFromClass([w class]), (int)[w isOpaque], [w alphaValue], [w title]);"
        " if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])"
        "   [w setValue:@NO forKey:@\"usePerPixelAlpha\"];"
        " if ([[w contentView] respondsToSelector:@selector(setShapeImage:)])"
        "   [[w contentView] performSelector:@selector(setShapeImage:) withObject:nil];"
        " if ([w respondsToSelector:@selector(checkTransparency)])"
        "   [w performSelector:@selector(checkTransparency)];"
        " [w setOpaque:YES];"
        " [w setBackgroundColor:[NSColor windowBackgroundColor]];"
        " [w contentView].layer.opaque=YES;"
        " [[w contentView] setNeedsDisplay:YES];"
        " [w displayIfNeeded];"
        " NSLog(@\"[pf] AFTER %@ opaque=%d contents=%@\","
        "  NSStringFromClass([w class]), (int)[w isOpaque], [w contentView].layer.contents);"
        " n++; } n;"
    )
    _cmd(debugger, "expr -l objc -- " + oneliner)

def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f present_force_lldb.force present_force")
    print("present_force command loaded")
