#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "LumenDisplayDrawing.h"

static NSString *envString(const char *key) {
    const char *value = getenv(key);
    return value ? [NSString stringWithUTF8String:value] : @"";
}

@interface LumenMenuController : NSObject <NSMenuItemValidation, NSMenuDelegate>
@property(nonatomic, copy) NSDictionary *status;
@property(nonatomic, retain) id executionActivity;
- (void)installMenus;
- (void)performAction:(NSMenuItem *)item;
- (void)sendAction:(NSString *)action;
- (void)writeMenuReport;
@end

static LumenMenuController *menuController;
static NSMenuItem *smoothDisplayItem;
static BOOL stableFramebufferDrawing;
static NSUInteger stableFramebufferDrawCount;

@implementation LumenMenuController

- (NSMenuItem *)add:(NSString *)title command:(NSString *)command to:(NSMenu *)menu key:(NSString *)key {
    NSMenuItem *item = [menu addItemWithTitle:title action:@selector(performAction:) keyEquivalent:key];
    item.target = self;
    item.representedObject = command;
    return item;
}

- (NSMenu *)submenu:(NSString *)title to:(NSMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *child = [[[NSMenu alloc] initWithTitle:title] autorelease];
    child.delegate = self;
    item.submenu = child;
    return child;
}

- (void)sendAction:(NSString *)action {
    NSString *token = envString("LUMEN_VM_CONTROL_TOKEN");
    if (!token.length) return;
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:[@"app.lumen.control." stringByAppendingString:token]
                      object:nil userInfo:@{@"action": action} deliverImmediately:YES];
}

- (void)performAction:(NSMenuItem *)item {
    if ([item.representedObject isEqual:@"toggle-fullscreen"]) {
        [NSApp.keyWindow toggleFullScreen:nil];
        return;
    }
    if ([item.representedObject isEqual:@"release-input"]) {
        for (NSWindow *window in NSApp.windows) {
            id view = window.contentView;
            if (![NSStringFromClass([view class]) isEqualToString:@"QemuCocoaView"]) continue;
            for (NSString *name in @[@"ungrabMouse", @"raiseAllKeys"]) {
                SEL selector = NSSelectorFromString(name);
                if ([view respondsToSelector:selector]) {
                    ((void (*)(id, SEL))[view methodForSelector:selector])(view, selector);
                }
            }
        }
        return;
    }
    [self sendAction:item.representedObject];
}
- (void)menuWillOpen:(NSMenu *)menu { [self sendAction:@"refresh"]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    NSString *command = item.representedObject;
    if ([command isEqual:@"toggle-fullscreen"]) {
        BOOL fullScreen = (NSApp.keyWindow.styleMask & NSWindowStyleMaskFullScreen) != 0;
        item.title = fullScreen ? @"Exit Full Screen" : @"Enter Full Screen";
        return NSApp.keyWindow != nil;
    }
    NSString *state = self.status[@"state"];
    BOOL running = [state isEqual:@"running"];
    BOOL paused = [state isEqual:@"paused"];
    if ([command isEqual:@"enable-retina"]) return running &&
        ![self.status[@"typing"] boolValue] && [self.status[@"compatibilityDisplay"] boolValue];
    if ([command isEqual:@"pause"]) return running;
    if ([command isEqual:@"resume"]) return paused;
    if ([command isEqual:@"shutdown"] || [command isEqual:@"reset"]) return running || paused;
    if ([command isEqual:@"force-stop"]) return running || paused || [state isEqual:@"stopping"];
    if ([command isEqual:@"guest-folders"]) return running && ![self.status[@"typing"] boolValue] && [self.status[@"sharedFolders"] boolValue];
    if ([command isEqual:@"install-drivers"] || [command hasPrefix:@"guest-"] || [command isEqual:@"secure-attention"]) {
        return running && ![self.status[@"typing"] boolValue];
    }
    if ([command isEqual:@"screenshot"]) return running || paused;
    if ([command hasPrefix:@"eject-"]) {
        return (running || paused) && [self.status[@"media"][command] boolValue];
    }
    if ([command hasPrefix:@"mount-"] || [command isEqual:@"change-installer"]) return running || paused;
    return YES;
}

- (NSArray *)describeMenu:(NSMenu *)menu {
    NSMutableArray *items = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.separatorItem) continue;
        NSMutableDictionary *description = [NSMutableDictionary dictionaryWithDictionary:@{
            @"title": item.title, @"enabled": @(item.enabled)
        }];
        if (item.target == self && [item.representedObject isKindOfClass:NSString.class]) {
            description[@"command"] = item.representedObject;
            description[@"enabled"] = @([self validateMenuItem:item]);
        }
        if (item.submenu) description[@"items"] = [self describeMenu:item.submenu];
        [items addObject:description];
    }
    return items;
}

- (void)writeMenuReport {
    NSString *path = envString("LUMEN_VM_MENU_REPORT");
    if (!path.length || !NSApp.mainMenu) return;
    NSDictionary *report = @{
        @"processName": NSProcessInfo.processInfo.processName,
        @"applicationName": NSRunningApplication.currentApplication.localizedName ?: @"",
        @"bundleName": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"",
        @"presentationOptions": @(NSApp.presentationOptions),
        @"stableFramebufferDrawing": @(stableFramebufferDrawing),
        @"stableFramebufferDrawCount": @(stableFramebufferDrawCount),
        @"fullScreen": @((NSApp.keyWindow.styleMask & NSWindowStyleMaskFullScreen) != 0),
        @"menus": [self describeMenu:NSApp.mainMenu],
        @"status": self.status ?: @{}
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];
}

- (void)receiveStatus:(NSNotification *)notification {
    self.status = notification.userInfo;
    NSString *state = self.status[@"state"];
    BOOL executing = [state isEqual:@"running"] || [state isEqual:@"starting"];
    if (executing && !self.executionActivity) {
        self.executionActivity = [[NSProcessInfo processInfo]
            beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
            reason:@"Running a virtual machine"];
    } else if (!executing && self.executionActivity) {
        [[NSProcessInfo processInfo] endActivity:self.executionActivity];
        self.executionActivity = nil;
    }
    [self writeMenuReport];
}

- (void)installMenus {
    NSMenu *main = NSApp.mainMenu;
    if (!main.numberOfItems || [main itemWithTitle:@"Devices"]) return;
    NSMenu *app = [main itemAtIndex:0].submenu;
    [app removeAllItems];
    [main itemAtIndex:0].title = @"Lumen VM";
    app.title = @"Lumen VM";
    [self add:@"About Lumen VM" command:@"about" to:app key:@""];
    [self add:@"Open Lumen Library" command:@"library" to:app key:@"l"];
    [self add:@"Virtual Machine Settings…" command:@"settings" to:app key:@","];
    [app addItem:NSMenuItem.separatorItem];
    NSMenuItem *services = [app addItemWithTitle:@"Services" action:nil keyEquivalent:@""];
    services.submenu = NSApp.servicesMenu;
    [app addItemWithTitle:@"Hide Lumen VM" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [app addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    [app addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [app addItem:NSMenuItem.separatorItem];
    [self add:@"Close Virtual Machine…" command:@"force-stop" to:app key:@"q"];

    NSMenuItem *machineItem = [main itemWithTitle:@"Machine"];
    NSMenu *machine = machineItem.submenu;
    [machine removeAllItems];
    machine.autoenablesItems = YES;
    machine.delegate = self;
    machineItem.title = @"Virtual Machine";
    machine.title = @"Virtual Machine";
    [self add:@"Pause" command:@"pause" to:machine key:@""];
    [self add:@"Resume" command:@"resume" to:machine key:@""];
    [machine addItem:NSMenuItem.separatorItem];
    [self add:@"Send Ctrl-Alt-Delete" command:@"secure-attention" to:machine key:@""];
    [self add:@"Restart Immediately…" command:@"reset" to:machine key:@""];
    [self add:@"Shut Down" command:@"shutdown" to:machine key:@""];
    [self add:@"Force Stop…" command:@"force-stop" to:machine key:@""];
    [machine addItem:NSMenuItem.separatorItem];
    [self add:@"Start All Machines" command:@"start-all" to:machine key:@""];
    [self add:@"Shut Down All Machines" command:@"stop-all" to:machine key:@""];
    [self add:@"Show Machine in Finder" command:@"reveal" to:machine key:@""];
    [self add:@"Open Diagnostic Log" command:@"log" to:machine key:@""];

    NSMenu *view = [main itemWithTitle:@"View"].submenu;
    view.delegate = self;
    // Retain QEMU's native full-screen/fit/interpolation handlers and their toggle states.
    for (NSMenuItem *item in [[view.itemArray copy] autorelease]) {
        if (item.action == NSSelectorFromString(@"doToggleFullScreen:")) {
            item.title = @"Enter Full Screen";
            item.action = @selector(performAction:);
            item.target = self;
            item.representedObject = @"toggle-fullscreen";
            item.keyEquivalent = @"f";
            item.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
        }
        if (item.action == NSSelectorFromString(@"displayConsole:")) [view removeItem:item];
        if (item.action == NSSelectorFromString(@"toggleZoomInterpolation:")) {
            smoothDisplayItem = item;
            item.title = @"Smooth Scaled Display";
            item.toolTip = @"Smooths stretched pixels. Turn off for sharper pixel edges; this does not add Retina resolution.";
        }
    }
    if (view.itemArray.lastObject.separatorItem) [view removeItem:view.itemArray.lastObject];
    [view addItem:NSMenuItem.separatorItem];
    [self add:@"Windows Display Settings…" command:@"guest-display" to:view key:@""];
    [self add:@"Enable Retina Display After Installing Drivers…" command:@"enable-retina" to:view key:@""];
    [self add:@"Save Screenshot…" command:@"screenshot" to:view key:@""];

    NSMenu *devices = [[[NSMenu alloc] initWithTitle:@"Devices"] autorelease];
    devices.delegate = self;
    NSMenuItem *devicesItem = [[[NSMenuItem alloc] initWithTitle:@"Devices" action:nil keyEquivalent:@""] autorelease];
    devicesItem.submenu = devices;
    [main insertItem:devicesItem atIndex:3];
    [self add:@"Install / Repair Guest Tools…" command:@"install-drivers" to:devices key:@""];
    [self add:@"Device Manager…" command:@"guest-devices" to:devices key:@""];
    [self add:@"Windows Network Settings…" command:@"guest-network" to:devices key:@""];
    [self add:@"Connect / Open Shared Folders…" command:@"guest-folders" to:devices key:@""];
    NSMenu *keyboard = [self submenu:@"Keyboard & Mouse" to:devices];
    [self add:@"Send Ctrl-Alt-Delete" command:@"secure-attention" to:keyboard key:@""];
    [self add:@"Send Windows Key" command:@"guest-windows-key" to:keyboard key:@""];
    [self add:@"Send Escape" command:@"guest-escape" to:keyboard key:@""];
    [self add:@"Release Keyboard & Mouse" command:@"release-input" to:keyboard key:@""];
    [devices addItem:NSMenuItem.separatorItem];
    NSMenu *installer = [self submenu:@"Windows Installer Disc" to:devices];
    [self add:@"Choose ISO…" command:@"change-installer" to:installer key:@""];
    [self add:@"Insert Configured Installer" command:@"mount-installer" to:installer key:@""];
    [self add:@"Eject Windows Installer" command:@"eject-installer" to:installer key:@""];
    NSMenu *drivers = [self submenu:@"ARM64 Driver Disc" to:devices];
    [self add:@"Insert Driver Disc" command:@"mount-drivers" to:drivers key:@""];
    [self add:@"Eject Driver Disc" command:@"eject-drivers" to:drivers key:@""];
    NSMenu *tools = [self submenu:@"Lumen Setup Tools Disc" to:devices];
    [self add:@"Insert Setup Tools" command:@"mount-setup" to:tools key:@""];
    [self add:@"Eject Setup Tools" command:@"eject-setup" to:tools key:@""];

    NSMenuItem *speed = [main itemWithTitle:@"Speed"];
    if (speed) {
        [speed retain];
        [main removeItem:speed];
        speed.title = @"CPU Speed Limit";
        [machine addItem:NSMenuItem.separatorItem];
        [machine addItem:speed];
        [speed release];
    }
    NSMenu *window = NSApp.windowsMenu;
    [window addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [window addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    NSMenu *help = [[[NSMenu alloc] initWithTitle:@"Help"] autorelease];
    [self add:@"Windows Drivers & Retina Guide" command:@"driver-guide" to:help key:@""];
    [self add:@"Guest Compatibility" command:@"compatibility" to:help key:@""];
    [self add:@"QEMU Engine Documentation" command:@"engine-docs" to:help key:@""];
    NSMenuItem *oldHelp = main.itemArray.lastObject;
    oldHelp.title = @"Help";
    oldHelp.submenu = help;
    NSApp.helpMenu = help;
    NSString *token = envString("LUMEN_VM_CONTROL_TOKEN");
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveStatus:)
        name:[@"app.lumen.status." stringByAppendingString:token] object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [self sendAction:@"ready"];
    [self writeMenuReport];
}
@end

static BOOL lumenVerifyQuit(id controller, SEL selector) {
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = [NSString stringWithFormat:@"Force stop %@?", envString("LUMEN_VM_NAME")];
    alert.informativeText = @"Unsaved work in Windows will be lost. Use Virtual Machine → Shut Down to save work first.";
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Force Stop"];
    return [alert runModal] == NSAlertSecondButtonReturn;
}

static BOOL isGuestWindow(NSWindow *window) {
    return [NSStringFromClass(window.contentView.class) isEqualToString:@"QemuCocoaView"];
}

// QEMU requests HideMenuBar, which disables macOS's top-edge reveal entirely.
// AutoHide preserves an immersive screen while retaining the system exit controls.
static NSApplicationPresentationOptions lumenFullScreenOptions(id controller, SEL selector,
    NSWindow *window, NSApplicationPresentationOptions proposed) {
    return (proposed & ~(NSApplicationPresentationHideMenuBar | NSApplicationPresentationHideDock)) |
        NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideDock;
}

static IMP originalSendEvent;
static void lumenSendEvent(id application, SEL selector, NSEvent *event) {
    if (event.type != NSEventTypeKeyDown) {
        ((void (*)(id, SEL, NSEvent *))originalSendEvent)(application, selector, event);
        return;
    }
    NSWindow *window = NSApp.keyWindow;
    NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL toggle = modifiers == (NSEventModifierFlagControl | NSEventModifierFlagCommand) && event.keyCode == 3;
    BOOL escape = modifiers == (NSEventModifierFlagControl | NSEventModifierFlagOption) && event.keyCode == 53;
    if (isGuestWindow(window) &&
        (toggle || (escape && (window.styleMask & NSWindowStyleMaskFullScreen)))) {
        // Intercept before QEMU forwards captured shortcuts to Windows.
        if (!event.isARepeat) [window toggleFullScreen:nil];
        return;
    }
    ((void (*)(id, SEL, NSEvent *))originalSendEvent)(application, selector, event);
}

static IMP originalDrawRect;
static NSDragOperation lumenDraggingEntered(id view, SEL selector, id<NSDraggingInfo> sender) {
    if (![menuController.status[@"state"] isEqual:@"running"] ||
        ![menuController.status[@"canReceiveFiles"] boolValue]) return NSDragOperationNone;
    return [sender.draggingPasteboard canReadObjectForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ? NSDragOperationCopy : NSDragOperationNone;
}

static BOOL lumenPerformDrag(id view, SEL selector, id<NSDraggingInfo> sender) {
    if (lumenDraggingEntered(view, selector, sender) == NSDragOperationNone) return NO;
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (urls.count == 0 || urls.count > 128) return NO;
    NSMutableArray *values = [NSMutableArray array];
    for (NSURL *url in urls) if (url.isFileURL) [values addObject:url.absoluteString];
    NSString *token = envString("LUMEN_VM_CONTROL_TOKEN");
    if (!token.length || values.count != urls.count) return NO;
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:[@"app.lumen.control." stringByAppendingString:token]
        object:nil userInfo:@{@"action": @"drop-files", @"urls": values} deliverImmediately:YES];
    return YES;
}

static BOOL lumenPrepareDrag(id view, SEL selector, id<NSDraggingInfo> sender) {
    return lumenDraggingEntered(view, selector, sender) != NSDragOperationNone;
}
static Ivar framebufferIvar;
static int (*framebufferWidth)(void *);
static int (*framebufferHeight)(void *);
static int (*framebufferStride)(void *);
static uint32_t (*framebufferFormat)(void *);
static void *(*framebufferData)(void *);

static void lumenDrawRect(NSView *view, SEL selector, NSRect dirty) {
    void *framebuffer = NULL;
    memcpy(&framebuffer, (const char *)view + ivar_getOffset(framebufferIvar), sizeof(framebuffer));
    // Retain the native renderer for a boot surface with a different pixel format.
    if (!framebuffer || (framebufferFormat(framebuffer) >> 24) != 32) {
        ((void (*)(id, SEL, NSRect))originalDrawRect)(view, selector, dirty);
        return;
    }
    int width = framebufferWidth(framebuffer), height = framebufferHeight(framebuffer);
    int stride = framebufferStride(framebuffer);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context || width <= 0 || height <= 0 || stride < width * 4) {
        ((void (*)(id, SEL, NSRect))originalDrawRect)(view, selector, dirty);
        return;
    }
    // Created once; drawRect runs on every guest frame.
    static CGColorSpaceRef colorSpace;
    if (!colorSpace) colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, framebufferData(framebuffer),
                                                            (size_t)stride * height, NULL);
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL, false, kCGRenderingIntentDefault);
    if (image) {
        stableFramebufferDrawCount++;
        LumenDrawFramebuffer(context, image, NSRectToCGRect(view.bounds),
                             smoothDisplayItem.state == NSControlStateValueOn);
        CGImageRelease(image);
    } else {
        ((void (*)(id, SEL, NSRect))originalDrawRect)(view, selector, dirty);
    }
    CGDataProviderRelease(provider);
}

static IMP originalUpdateUIInfo;
static void lumenUpdateUIInfo(id view, SEL selector) {
    const char *resize = getenv("LUMEN_VM_AUTO_RESIZE");
    NSView *displayView = (NSView *)view;
    NSWindow *window = displayView.window;
    // During lock, display changes or minimization Cocoa can briefly lose its screen.
    // Keep the last usable guest mode instead of publishing zero/invalid geometry.
    NSSize size = displayView.frame.size;
    if (window && window.screen && !window.isMiniaturized &&
        size.width >= 64 && size.height >= 64 &&
        (!resize || strcmp(resize, "0") != 0)) {
        ((void (*)(id, SEL))originalUpdateUIInfo)(view, selector);
    }
}

static IMP originalResizeWindow;
static void lumenResizeWindow(id view, SEL selector) {
    const char *resize = getenv("LUMEN_VM_AUTO_RESIZE");
    NSWindow *window = [(NSView *)view window];
    if (resize && strcmp(resize, "1") == 0 &&
        (window.styleMask & NSWindowStyleMaskResizable)) {
        // The guest follows the window in this mode. Retaining QEMU's previous
        // framebuffer aspect ratio would constrain subsequent host resizing.
        window.contentResizeIncrements = NSMakeSize(1, 1);
        return;
    }
    ((void (*)(id, SEL))originalResizeWindow)(view, selector);
}

@interface NSWindow (LumenHelper)
- (void)lumen_setTitle:(NSString *)title;
- (void)lumen_makeKeyAndOrderFront:(id)sender;
@end

@implementation NSWindow (LumenHelper)

- (void)lumen_setTitle:(NSString *)title {
    const char *vmName = getenv("LUMEN_VM_NAME");
    if (vmName && strlen(vmName) > 0 && (isGuestWindow(self) || [title hasPrefix:@"QEMU"])) {
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
    if (!isGuestWindow(self)) {
        [self lumen_makeKeyAndOrderFront:sender];
        return;
    }
    [self setTabbingMode:NSWindowTabbingModeDisallowed];
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
        // Record dimensions are guest pixels; Cocoa window sizes are points.
        // 2560×1600 pixels at 2× needs a 1280×800-point window for sharp Retina text.
        CGFloat backingScale = screen ? screen.backingScaleFactor : 1.0;
        targetW /= backingScale;
        targetH /= backingScale;
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
                [self setRepresentedURL:[NSURL fileURLWithPath:[[NSFileManager defaultManager] currentDirectoryPath]]];
                NSButton *proxy = [self standardWindowButton:NSWindowDocumentIconButton];
                [proxy setImage:icon];
                [proxy setHidden:NO];
                [self setMiniwindowImage:icon];
                if (vmName) [self setMiniwindowTitle:[NSString stringWithUTF8String:vmName]];
            }
        }

    }

    [self lumen_makeKeyAndOrderFront:sender];
    [self.contentView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
}

@end

__attribute__((constructor))
static void initLumenHelper(void) {
    [NSProcessInfo.processInfo setProcessName:@"Lumen VM"];
    menuController = [[LumenMenuController alloc] init];
    menuController.executionActivity = [[NSProcessInfo processInfo]
        beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
        reason:@"Starting a virtual machine"];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            // QEMU creates/appends its menus after creating the window. Wait for launch completion.
            dispatch_async(dispatch_get_main_queue(), ^{ [menuController installMenus]; });
        }];
    for (NSString *name in @[NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) {
                dispatch_async(dispatch_get_main_queue(), ^{ [menuController writeMenuReport]; });
            }];
    }
    Method verifyQuit = class_getInstanceMethod(NSClassFromString(@"QemuCocoaAppController"), NSSelectorFromString(@"verifyQuit"));
    if (verifyQuit) method_setImplementation(verifyQuit, (IMP)lumenVerifyQuit);
    Method fullScreenOptions = class_getInstanceMethod(NSClassFromString(@"QemuCocoaAppController"),
        NSSelectorFromString(@"window:willUseFullScreenPresentationOptions:"));
    if (fullScreenOptions) method_setImplementation(fullScreenOptions, (IMP)lumenFullScreenOptions);
    Method sendEvent = class_getInstanceMethod(NSClassFromString(@"QemuApplication"), @selector(sendEvent:));
    if (sendEvent) originalSendEvent = method_setImplementation(sendEvent, (IMP)lumenSendEvent);
    // QEMU's Cocoa backend reports window pixels to VirtIO GPU. Respect fixed-resolution mode.
    Class guestView = NSClassFromString(@"QemuCocoaView");
    class_addMethod(guestView, @selector(draggingEntered:), (IMP)lumenDraggingEntered, "Q@:@");
    class_addMethod(guestView, @selector(draggingUpdated:), (IMP)lumenDraggingEntered, "Q@:@");
    class_addMethod(guestView, @selector(prepareForDragOperation:), (IMP)lumenPrepareDrag, "B@:@");
    class_addMethod(guestView, @selector(performDragOperation:), (IMP)lumenPerformDrag, "B@:@");
    framebufferIvar = class_getInstanceVariable(guestView, "pixman_image");
    framebufferWidth = dlsym(RTLD_DEFAULT, "pixman_image_get_width");
    framebufferHeight = dlsym(RTLD_DEFAULT, "pixman_image_get_height");
    framebufferStride = dlsym(RTLD_DEFAULT, "pixman_image_get_stride");
    framebufferFormat = dlsym(RTLD_DEFAULT, "pixman_image_get_format");
    framebufferData = dlsym(RTLD_DEFAULT, "pixman_image_get_data");
    Method drawRect = class_getInstanceMethod(guestView, @selector(drawRect:));
    if (framebufferIvar && drawRect && framebufferWidth && framebufferHeight &&
        framebufferStride && framebufferFormat && framebufferData) {
        originalDrawRect = method_setImplementation(drawRect, (IMP)lumenDrawRect);
        stableFramebufferDrawing = YES;
    }
    Method updateUIInfo = class_getInstanceMethod(guestView, NSSelectorFromString(@"updateUIInfo"));
    if (updateUIInfo) {
        originalUpdateUIInfo = method_setImplementation(updateUIInfo, (IMP)lumenUpdateUIInfo);
    }
    Method resizeWindow = class_getInstanceMethod(guestView, NSSelectorFromString(@"resizeWindow"));
    if (resizeWindow) {
        originalResizeWindow = method_setImplementation(resizeWindow, (IMP)lumenResizeWindow);
    }
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
