#import <AppKit/AppKit.h>
#import <objc/runtime.h>

@interface NSWindow (LumenHelper)
- (void)lumen_setTitle:(NSString *)title;
- (void)lumen_makeKeyAndOrderFront:(id)sender;
@end

@implementation NSWindow (LumenHelper)

- (void)lumen_setTitle:(NSString *)title {
    const char *vmName = getenv("LUMEN_VM_NAME");
    if (vmName && strlen(vmName) > 0) {
        NSString *clean = [NSString stringWithUTF8String:vmName];
        if ([title containsString:@"[Paused]"] || [title containsString:@"(Paused)"]) {
            clean = [clean stringByAppendingString:@" — Paused"];
        }
        [self lumen_setTitle:clean];
    } else {
        if ([title hasPrefix:@"QEMU "]) {
            title = [title substringFromIndex:5];
        }
        [self lumen_setTitle:title];
    }
}

- (void)lumen_makeKeyAndOrderFront:(id)sender {
    static BOOL sized = NO;
    const char *vmName = getenv("LUMEN_VM_NAME");
    const char *iconPath = getenv("LUMEN_VM_ICON");
    const char *wStr = getenv("LUMEN_VM_WIDTH");
    const char *hStr = getenv("LUMEN_VM_HEIGHT");

    if (vmName && strlen(vmName) > 0) {
        [self setTitle:[NSString stringWithUTF8String:vmName]];
    }

    if (!sized && [self contentView] != nil) {
        sized = YES;
        CGFloat targetW = 1280.0;
        CGFloat targetH = 800.0;
        if (wStr) {
            CGFloat w = atof(wStr);
            if (w >= 800.0) targetW = w;
        }
        if (hStr) {
            CGFloat h = atof(hStr);
            if (h >= 600.0) targetH = h;
        }

        NSScreen *screen = [NSScreen mainScreen];
        if (screen) {
            NSRect visible = [screen visibleFrame];
            if (targetW > visible.size.width * 0.88) {
                CGFloat scale = (visible.size.width * 0.88) / targetW;
                targetW *= scale;
                targetH *= scale;
            }
            if (targetH > visible.size.height * 0.88) {
                CGFloat scale = (visible.size.height * 0.88) / targetH;
                targetW *= scale;
                targetH *= scale;
            }
        }

        [self setContentSize:NSMakeSize(targetW, targetH)];
        [self center];

        // Replace black terminal dock icon with the guest OS icon
        if (iconPath && strlen(iconPath) > 0) {
            NSString *path = [NSString stringWithUTF8String:iconPath];
            NSImage *icon = [[NSImage alloc] initWithContentsOfFile:path];
            if (icon) {
                [NSApp setApplicationIconImage:icon];
            }
        }

        // Rename main menu item from QEMU to actual VM name
        NSMenu *mainMenu = [NSApp mainMenu];
        if (mainMenu && mainMenu.numberOfItems > 0 && vmName) {
            NSMenuItem *appItem = [mainMenu itemAtIndex:0];
            NSString *cleanName = [NSString stringWithUTF8String:vmName];
            [appItem setTitle:cleanName];
            if (appItem.submenu) {
                [appItem.submenu setTitle:cleanName];
            }
        }
    }

    [self lumen_makeKeyAndOrderFront:sender];
}

@end

__attribute__((constructor))
static void initLumenHelper(void) {
    Method origTitle = class_getInstanceMethod([NSWindow class], @selector(setTitle:));
    Method swizTitle = class_getInstanceMethod([NSWindow class], @selector(lumen_setTitle:));
    if (origTitle && swizTitle) {
        method_exchangeImplementations(origTitle, swizTitle);
    }

    Method origOrder = class_getInstanceMethod([NSWindow class], @selector(makeKeyAndOrderFront:));
    Method swizOrder = class_getInstanceMethod([NSWindow class], @selector(lumen_makeKeyAndOrderFront:));
    if (origOrder && swizOrder) {
        method_exchangeImplementations(origOrder, swizOrder);
    }
}
