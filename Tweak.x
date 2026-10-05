// SlideCutPlus — touch the space key, slide to a letter, release → editing shortcut.
// Clean-room rewrite of SlideCut (r_plus) targeting iOS 15+.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - Private interfaces

@interface UIKBTree : NSObject
- (NSString *)name;
- (NSString *)unhashedName;
- (NSString *)representedString;
- (NSString *)displayString;
- (NSString *)variantDisplayString;
- (NSDictionary *)properties;
@end

@interface UIKBTouchState : NSObject
+ (instancetype)touchStateForTouchUUID:(NSUUID *)uuid withTimestamp:(NSTimeInterval)timestamp phase:(UITouchPhase)phase location:(CGPoint)location pathIndex:(unsigned char)pathIndex inView:(UIView *)view;
- (NSUUID *)touchUUID;
- (NSUInteger)tapCount;
- (NSTimeInterval)timestamp;
- (NSUInteger)pathIndex;
- (CGPoint)locationInView:(UIView *)view;
@end

@interface UIKeyboardTaskExecutionContext : NSObject
@end

@interface UIKeyboardLayoutStar : UIView
- (UIKBTree *)keyHitTest:(CGPoint)point;
- (void)touchCancelled:(UIKBTouchState *)touch executionContext:(UIKeyboardTaskExecutionContext *)context;
@end

@interface UIKBInputDelegateManager : NSObject
- (void)insertText:(NSString *)text;
@end

@interface UIKeyboardImpl : UIView
+ (instancetype)sharedInstance;
+ (instancetype)activeInstance;
- (id)delegateAsResponder;
- (id)inputDelegate;
- (UIKBInputDelegateManager *)inputDelegateManager;
- (void)deleteBackward;
- (void)insertText:(NSString *)text;
@end

@interface UIFieldEditor : UIView
+ (instancetype)sharedFieldEditor;
- (void)revealSelection;
@end

@interface UIResponder (SlideCutPlusPrivate)
- (void)executeEditCommandWithCallback:(NSString *)command;  // WKContentView
- (NSString *)selectedText;                                   // WKContentView
- (void)selectWordBackward;
- (void)scrollSelectionToVisible:(BOOL)animated;
- (void)_define:(id)term;
- (void)_translate:(id)sender;
- (void)_moveLeft:(BOOL)extending withHistory:(id)history;
- (void)_moveRight:(BOOL)extending withHistory:(id)history;
- (void)_moveUp:(BOOL)extending withHistory:(id)history;
- (void)_moveDown:(BOOL)extending withHistory:(id)history;
- (void)_moveToStartOfLine:(BOOL)extending withHistory:(id)history;
- (void)_moveToEndOfLine:(BOOL)extending withHistory:(id)history;
- (void)_moveToStartOfWord:(BOOL)extending withHistory:(id)history;
- (void)_moveToEndOfWord:(BOOL)extending withHistory:(id)history;
- (void)_moveToStartOfDocument:(BOOL)extending withHistory:(id)history;
- (void)_moveToEndOfDocument:(BOOL)extending withHistory:(id)history;
@end

#pragma mark - State

typedef NS_ENUM(NSInteger, SCPAction) {
    SCPActionNone = 0,
    SCPActionCut,
    SCPActionCopy,
    SCPActionPaste,
    SCPActionSelectAll,
    SCPActionUndo,
    SCPActionRedo,
    SCPActionLineStart,
    SCPActionLineEnd,
    SCPActionDocumentStart,
    SCPActionDocumentEnd,
    SCPActionSelectWord,
    SCPActionMoveLeft,
    SCPActionMoveDown,
    SCPActionMoveUp,
    SCPActionMoveRight,
    SCPActionTranslate,
    SCPActionPreviousWord,
    SCPActionNextWord,
    SCPActionDeleteWord,
};

static NSDictionary<NSString *, NSNumber *> *SCPKeyMap;

// touchUUIDs of keyboard touches that went down on the space key.
static NSMutableSet<NSUUID *> *gSpaceTouches;

#pragma mark - Key helpers

static BOOL SCPIsSpaceKey(UIKBTree *key) {
    if (!key) return NO;
    NSString *name = [key respondsToSelector:@selector(unhashedName)] ? [key unhashedName] : [key name];
    if ([name isEqualToString:@"Space-Key"] || [name isEqualToString:@"Unlabeled-Space-Key"]) return YES;
    return [key respondsToSelector:@selector(representedString)] && [[key representedString] isEqualToString:@" "];
}

static SCPAction SCPActionForKey(UIKBTree *key) {
    if (!key || SCPIsSpaceKey(key)) return SCPActionNone;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if ([key respondsToSelector:@selector(representedString)] && [key representedString]) [candidates addObject:[key representedString]];
    if ([key respondsToSelector:@selector(variantDisplayString)] && [key variantDisplayString]) [candidates addObject:[key variantDisplayString]];
    if ([key respondsToSelector:@selector(displayString)] && [key displayString]) [candidates addObject:[key displayString]];
    if ([key respondsToSelector:@selector(properties)]) {
        id represented = [key properties][@"KBrepresentedString"];
        if ([represented isKindOfClass:[NSString class]]) [candidates addObject:represented];
    }

    for (NSString *candidate in candidates) {
        NSNumber *action = SCPKeyMap[candidate.lowercaseString];
        if (action) return (SCPAction)action.integerValue;
    }
    return SCPActionNone;
}

#pragma mark - Text helpers

static UIKeyboardImpl *SCPKeyboardImpl(void) {
    Class cls = objc_getClass("UIKeyboardImpl");
    if ([cls respondsToSelector:@selector(activeInstance)]) {
        UIKeyboardImpl *impl = [cls activeInstance];
        if (impl) return impl;
    }
    return [cls sharedInstance];
}

static id SCPDelegate(UIKeyboardImpl *impl) {
    id delegate = nil;
    if ([impl respondsToSelector:@selector(delegateAsResponder)]) delegate = [impl delegateAsResponder];
    if (!delegate && [impl respondsToSelector:@selector(inputDelegate)]) delegate = [impl inputDelegate];
    return delegate;
}

static BOOL SCPIsWebView(id delegate) {
    static Class wkContentView;
    if (!wkContentView) wkContentView = objc_getClass("WKContentView");
    return wkContentView && [delegate isKindOfClass:wkContentView];
}

static BOOL SCPWebCommand(id delegate, NSString *command) {
    if (![delegate respondsToSelector:@selector(executeEditCommandWithCallback:)]) return NO;
    [delegate executeEditCommandWithCallback:command];
    return YES;
}

// WebCore editing command, falling back to the private UITextInput `_move…:withHistory:` method.
static void SCPWebMove(id delegate, NSString *command, SEL fallback) {
    if (SCPWebCommand(delegate, command)) return;
    if ([delegate respondsToSelector:fallback]) ((void (*)(id, SEL, BOOL, id))objc_msgSend)(delegate, fallback, NO, nil);
}

// Letters (including Vietnamese with combining marks), digits and underscore.
static NSCharacterSet *SCPWordCharacters(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *characters = [NSMutableCharacterSet alphanumericCharacterSet];
        [characters formUnionWithCharacterSet:[NSCharacterSet nonBaseCharacterSet]];
        [characters addCharactersInString:@"_"];
        set = [characters copy];
    });
    return set;
}

static BOOL SCPIsTextInput(id delegate) {
    return [delegate conformsToProtocol:@protocol(UITextInput)] && [delegate respondsToSelector:@selector(selectedTextRange)];
}

static NSString *SCPSelectedText(id delegate) {
    NSString *text = nil;
    if (SCPIsTextInput(delegate)) {
        UITextRange *range = [delegate selectedTextRange];
        if (range && !range.isEmpty) text = [delegate textInRange:range];
    }
    if (!text.length && SCPIsWebView(delegate) && [delegate respondsToSelector:@selector(selectedText)]) {
        text = [delegate selectedText];
    }
    return text;
}

static void SCPReveal(id<UITextInput> delegate) {
    Class fieldEditorClass = objc_getClass("UIFieldEditor");
    if ([fieldEditorClass respondsToSelector:@selector(sharedFieldEditor)]) {
        UIFieldEditor *editor = [fieldEditorClass sharedFieldEditor];
        if ([editor respondsToSelector:@selector(revealSelection)]) [editor revealSelection];
        else if ([editor respondsToSelector:@selector(scrollSelectionToVisible:)]) [editor scrollSelectionToVisible:YES];
    }
    if ([(id)delegate respondsToSelector:@selector(scrollSelectionToVisible:)]) {
        [(id)delegate scrollSelectionToVisible:YES];
    } else if ([(id)delegate isKindOfClass:[UITextView class]]) {
        UITextView *textView = (UITextView *)delegate;
        [textView scrollRangeToVisible:textView.selectedRange];
    }
}

static void SCPSetCaret(id<UITextInput> delegate, UITextPosition *position) {
    if (!position) return;
    UITextRange *range = [delegate textRangeFromPosition:position toPosition:position];
    if (!range) return;
    delegate.selectedTextRange = range;
    SCPReveal(delegate);
}

// Range of the word enclosing the caret, falling back to the nearest word
// in `direction` (UITextStorageDirectionForward / Backward).
static UITextRange *SCPWordRange(id<UITextInput> delegate, UITextStorageDirection direction) {
    id<UITextInputTokenizer> tokenizer = delegate.tokenizer;
    UITextRange *selection = delegate.selectedTextRange;
    if (!tokenizer || !selection) return nil;

    UITextRange *range = [tokenizer rangeEnclosingPosition:selection.start withGranularity:UITextGranularityWord inDirection:(UITextDirection)direction];
    if (range) return range;

    UITextPosition *position;
    if (direction == UITextStorageDirectionBackward) {
        position = [tokenizer positionFromPosition:selection.start toBoundary:UITextGranularityWord inDirection:(UITextDirection)UITextStorageDirectionBackward];
        if (!position) position = [tokenizer positionFromPosition:selection.start toBoundary:UITextGranularityLine inDirection:(UITextDirection)UITextLayoutDirectionUp];
    } else {
        position = [tokenizer positionFromPosition:selection.start toBoundary:UITextGranularityWord inDirection:(UITextDirection)UITextStorageDirectionForward];
        if (!position) position = [tokenizer positionFromPosition:selection.end toBoundary:UITextGranularityLine inDirection:(UITextDirection)UITextLayoutDirectionDown];
    }
    if (!position) return nil;
    return [tokenizer rangeEnclosingPosition:position withGranularity:UITextGranularityWord inDirection:(UITextDirection)direction];
}

static UITextRange *SCPWordRangeAtCaret(id<UITextInput> delegate) {
    UITextRange *selection = delegate.selectedTextRange;
    if (!selection) return nil;
    BOOL insideWord = [delegate.tokenizer isPosition:selection.start withinTextUnit:UITextGranularityWord inDirection:(UITextDirection)UITextLayoutDirectionRight];
    return SCPWordRange(delegate, insideWord ? UITextStorageDirectionForward : UITextStorageDirectionBackward);
}

// Select the word at the caret when nothing is selected. Returns whether a selection exists afterwards.
static BOOL SCPEnsureSelection(id delegate) {
    if (SCPSelectedText(delegate).length) return YES;
    if (SCPIsWebView(delegate)) return SCPWebCommand(delegate, @"selectWord");
    if (!SCPIsTextInput(delegate)) return NO;
    UITextRange *range = SCPWordRangeAtCaret(delegate);
    if (!range || range.isEmpty) return NO;
    [delegate setSelectedTextRange:range];
    return YES;
}

// From the caret back to the start of the previous word (skipping trailing whitespace).
static UITextRange *SCPDeleteWordRange(id<UITextInput> delegate) {
    UITextRange *selection = delegate.selectedTextRange;
    id<UITextInputTokenizer> tokenizer = delegate.tokenizer;
    if (!selection || !tokenizer) return nil;

    UITextPosition *caret = selection.start;
    UITextPosition *position = caret;
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (int i = 0; i < 3; i++) {
        UITextPosition *previous = [tokenizer positionFromPosition:position toBoundary:UITextGranularityWord inDirection:(UITextDirection)UITextStorageDirectionBackward];
        if (!previous || [delegate comparePosition:previous toPosition:position] != NSOrderedAscending) break;
        position = previous;
        NSString *text = [delegate textInRange:[delegate textRangeFromPosition:position toPosition:caret]];
        if ([text stringByTrimmingCharactersInSet:whitespace].length) break;
    }
    if ([delegate comparePosition:position toPosition:caret] == NSOrderedSame) {
        position = [delegate positionFromPosition:caret offset:-1];
        if (!position) return nil;
    }
    return [delegate textRangeFromPosition:position toPosition:caret];
}

static void SCPDeleteBackward(UIKeyboardImpl *impl, id delegate) {
    if ([impl respondsToSelector:@selector(deleteBackward)]) [impl deleteBackward];
    else if ([delegate respondsToSelector:@selector(deleteBackward)]) [delegate deleteBackward];
}

// Insert through the keyboard so it (and kbd's input context) stays in sync with the document.
static void SCPInsertText(UIKeyboardImpl *impl, id delegate, NSString *text) {
    if (!text.length) return;
    UIKBInputDelegateManager *manager = [impl respondsToSelector:@selector(inputDelegateManager)] ? [impl inputDelegateManager] : nil;
    if ([manager respondsToSelector:@selector(insertText:)]) [manager insertText:text];
    else if ([impl respondsToSelector:@selector(insertText:)]) [impl insertText:text];
    else if ([delegate respondsToSelector:@selector(insertText:)]) [delegate insertText:text];
}

static BOOL SCPCanPerform(id delegate, SEL action) {
    if (![delegate respondsToSelector:action]) return NO;
    return SCPIsWebView(delegate) || [delegate canPerformAction:action withSender:nil];
}

static void SCPMoveCaret(id delegate, UITextLayoutDirection direction) {
    if (SCPIsWebView(delegate)) {
        switch (direction) {
            case UITextLayoutDirectionRight: SCPWebMove(delegate, @"moveRight", @selector(_moveRight:withHistory:)); break;
            case UITextLayoutDirectionLeft:  SCPWebMove(delegate, @"moveLeft", @selector(_moveLeft:withHistory:)); break;
            case UITextLayoutDirectionUp:    SCPWebMove(delegate, @"moveUp", @selector(_moveUp:withHistory:)); break;
            case UITextLayoutDirectionDown:  SCPWebMove(delegate, @"moveDown", @selector(_moveDown:withHistory:)); break;
        }
        return;
    }
    if (!SCPIsTextInput(delegate)) return;
    UITextRange *selection = [delegate selectedTextRange];
    BOOL forward = direction == UITextLayoutDirectionRight || direction == UITextLayoutDirectionDown;
    // With a selection, left/right collapse it to the matching edge (standard behaviour).
    if (!selection.isEmpty && (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionRight)) {
        SCPSetCaret(delegate, forward ? selection.end : selection.start);
        return;
    }
    UITextPosition *origin = forward ? selection.end : selection.start;
    SCPSetCaret(delegate, [delegate positionFromPosition:origin inDirection:direction offset:1]);
}

static void SCPMoveToLineBoundary(id delegate, BOOL toEnd) {
    if (SCPIsWebView(delegate)) {
        if (toEnd) SCPWebMove(delegate, @"moveToEndOfLine", @selector(_moveToEndOfLine:withHistory:));
        else SCPWebMove(delegate, @"moveToBeginningOfLine", @selector(_moveToStartOfLine:withHistory:));
        return;
    }
    if (!SCPIsTextInput(delegate)) return;
    UITextRange *selection = [delegate selectedTextRange];
    UITextLayoutDirection direction = toEnd ? UITextLayoutDirectionRight : UITextLayoutDirectionLeft;
    UITextPosition *origin = toEnd ? selection.end : selection.start;
    SCPSetCaret(delegate, [[delegate tokenizer] positionFromPosition:origin toBoundary:UITextGranularityLine inDirection:(UITextDirection)direction]);
}

static void SCPMoveToDocumentBoundary(id delegate, BOOL toEnd) {
    if (SCPIsWebView(delegate)) {
        if (toEnd) SCPWebMove(delegate, @"moveToEndOfDocument", @selector(_moveToEndOfDocument:withHistory:));
        else SCPWebMove(delegate, @"moveToBeginningOfDocument", @selector(_moveToStartOfDocument:withHistory:));
        return;
    }
    if (!SCPIsTextInput(delegate)) return;
    SCPSetCaret(delegate, toEnd ? [delegate endOfDocument] : [delegate beginningOfDocument]);
}

static void SCPMoveByWord(id delegate, BOOL forward) {
    if (SCPIsWebView(delegate)) {
        if (forward) SCPWebMove(delegate, @"moveWordForward", @selector(_moveToEndOfWord:withHistory:));
        else SCPWebMove(delegate, @"moveWordBackward", @selector(_moveToStartOfWord:withHistory:));
        return;
    }
    if (!SCPIsTextInput(delegate)) return;

    if (forward) {
        UITextRange *word = SCPWordRange(delegate, UITextStorageDirectionForward);
        if (word) SCPSetCaret(delegate, word.end);
        return;
    }

    // Backward lands right after the previous word's last letter ("abc def xyz|" -> "abc def| xyz"),
    // not at the start of the current word, so a new word can be typed without Telex
    // attaching to the word on the right.
    static const NSInteger kWindow = 4096;
    UITextRange *selection = [delegate selectedTextRange];
    if (!selection) return;
    UITextPosition *caret = selection.start;
    NSInteger length = MIN([delegate offsetFromPosition:[delegate beginningOfDocument] toPosition:caret], kWindow);
    if (length <= 0) return;

    UITextRange *windowRange = [delegate textRangeFromPosition:[delegate positionFromPosition:caret offset:-length] toPosition:caret];
    NSString *text = windowRange ? [delegate textInRange:windowRange] : nil;
    if (!text.length) return;

    NSCharacterSet *wordCharacters = SCPWordCharacters();

    // Skip the word the caret is in (if any), then the whitespace/punctuation before it.
    NSInteger index = (NSInteger)text.length;
    while (index > 0 && [wordCharacters characterIsMember:[text characterAtIndex:index - 1]]) index--;
    while (index > 0 && ![wordCharacters characterIsMember:[text characterAtIndex:index - 1]]) index--;
    SCPSetCaret(delegate, [delegate positionFromPosition:caret offset:index - (NSInteger)text.length]);
}

#pragma mark - Actions

static void SCPPerform(SCPAction action) {
    UIKeyboardImpl *impl = SCPKeyboardImpl();
    id delegate = SCPDelegate(impl);
    if (!delegate) return;
    BOOL web = SCPIsWebView(delegate);

    switch (action) {
        case SCPActionCut:
        case SCPActionCopy: {
            BOOL cut = action == SCPActionCut;
            if (!SCPEnsureSelection(delegate)) break;
            SEL sel = cut ? @selector(cut:) : @selector(copy:);
            if (SCPCanPerform(delegate, sel)) {
                ((void (*)(id, SEL, id))objc_msgSend)(delegate, sel, nil);
            } else {
                NSString *text = SCPSelectedText(delegate);
                if (!text.length) break;
                [UIPasteboard generalPasteboard].string = text;
                if (cut) SCPDeleteBackward(impl, delegate);
            }
            break;
        }
        case SCPActionPaste: {
            UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
            // Text is inserted as plain text through the keyboard, followed by a space so the
            // next word can be typed straight away. paste: is avoided for text because on
            // iOS 16+ it can finish asynchronously, which would put the space before the paste.
            NSString *text = pasteboard.hasStrings ? pasteboard.string : nil;
            if (text.length) {
                unichar last = [text characterAtIndex:text.length - 1];
                if (![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:last]) text = [text stringByAppendingString:@" "];
                SCPInsertText(impl, delegate, text);
            } else if (pasteboard.hasImages && SCPCanPerform(delegate, @selector(paste:))) {
                [delegate paste:nil];
            }
            break;
        }
        case SCPActionSelectAll:
            if ([delegate respondsToSelector:@selector(selectAll:)]) [delegate selectAll:nil];
            else if (web) SCPWebCommand(delegate, @"selectAll");
            break;
        case SCPActionUndo:
        case SCPActionRedo: {
            BOOL undo = action == SCPActionUndo;
            NSUndoManager *manager = [delegate respondsToSelector:@selector(undoManager)] ? [delegate undoManager] : nil;
            if (manager && (undo ? manager.canUndo : manager.canRedo)) {
                if (undo) [manager undo]; else [manager redo];
            } else if (web) {
                SCPWebCommand(delegate, undo ? @"undo" : @"redo");
            }
            break;
        }
        case SCPActionLineStart:     SCPMoveToLineBoundary(delegate, NO); break;
        case SCPActionLineEnd:       SCPMoveToLineBoundary(delegate, YES); break;
        case SCPActionDocumentStart: SCPMoveToDocumentBoundary(delegate, NO); break;
        case SCPActionDocumentEnd:   SCPMoveToDocumentBoundary(delegate, YES); break;
        case SCPActionSelectWord:
            if (web) {
                if (!SCPWebCommand(delegate, @"selectWord") && [delegate respondsToSelector:@selector(selectWordBackward)]) [delegate selectWordBackward];
            } else {
                SCPEnsureSelection(delegate);
            }
            break;
        case SCPActionMoveLeft:  SCPMoveCaret(delegate, UITextLayoutDirectionLeft); break;
        case SCPActionMoveDown:  SCPMoveCaret(delegate, UITextLayoutDirectionDown); break;
        case SCPActionMoveUp:    SCPMoveCaret(delegate, UITextLayoutDirectionUp); break;
        case SCPActionMoveRight: SCPMoveCaret(delegate, UITextLayoutDirectionRight); break;
        case SCPActionTranslate: {
            // iOS 15+ has the system Translate action; iOS 14 falls back to Look Up.
            BOOL canTranslate = [delegate respondsToSelector:@selector(_translate:)];
            if (!canTranslate && ![delegate respondsToSelector:@selector(_define:)]) break;
            BOOL hadSelection = SCPSelectedText(delegate).length > 0;
            if (!SCPEnsureSelection(delegate)) break;
            void (^show)(void) = ^{
                if (canTranslate) [delegate _translate:nil];
                else [delegate _define:SCPSelectedText(delegate)];
            };
            // WebKit updates the selection asynchronously.
            if (web && !hadSelection) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), show);
            else show();
            break;
        }
        case SCPActionPreviousWord: SCPMoveByWord(delegate, NO); break;
        case SCPActionNextWord:     SCPMoveByWord(delegate, YES); break;
        case SCPActionDeleteWord:
            if (web) {
                if (SCPWebCommand(delegate, @"deleteWordBackward")) break;
                if ([delegate respondsToSelector:@selector(selectWordBackward)]) [delegate selectWordBackward];
                SCPDeleteBackward(impl, delegate);
                break;
            }
            if (SCPIsTextInput(delegate) && ![delegate selectedTextRange].isEmpty) {
                SCPDeleteBackward(impl, delegate);
                break;
            }
            if (SCPIsTextInput(delegate)) {
                UITextRange *range = SCPDeleteWordRange(delegate);
                if (!range) break;
                [delegate setSelectedTextRange:range];
                SCPDeleteBackward(impl, delegate);
            }
            break;
        case SCPActionNone:
            break;
    }
}

#pragma mark - Hooks

%hook UIKeyboardLayoutStar

// iOS 13+ turns UITouches into UIKBTouchState and runs them on the keyboard task queue.
// touchUp:executionContext: is where the released key is sent to the input manager (kbd),
// so this is the only place where the letter can be reliably kept from being typed —
// cancelling at the UITouch level is too late (the touch's phase is already Ended).

- (void)touchDown:(UIKBTouchState *)touch executionContext:(UIKeyboardTaskExecutionContext *)context {
    NSUUID *uuid = [touch touchUUID];
    if (uuid) {
        if (touch.tapCount > 0 && SCPIsSpaceKey([self keyHitTest:[touch locationInView:self]])) [gSpaceTouches addObject:uuid];
        else [gSpaceTouches removeObject:uuid];
    }
    %orig;
}

- (void)touchUp:(UIKBTouchState *)touch executionContext:(UIKeyboardTaskExecutionContext *)context {
    NSUUID *uuid = [touch touchUUID];
    if (!uuid || ![gSpaceTouches containsObject:uuid]) {
        %orig;
        return;
    }
    [gSpaceTouches removeObject:uuid];

    SCPAction action = SCPActionForKey([self keyHitTest:[touch locationInView:self]]);
    if (action == SCPActionNone) {
        %orig;
        return;
    }

    // Turn the touch-up into a cancel: the keyboard cleans up the touch (highlight, popups)
    // and returns the execution context, but nothing reaches the input manager.
    Class touchStateClass = objc_getClass("UIKBTouchState");
    UIKBTouchState *cancelled = nil;
    if ([touchStateClass respondsToSelector:@selector(touchStateForTouchUUID:withTimestamp:phase:location:pathIndex:inView:)]) {
        cancelled = [touchStateClass touchStateForTouchUUID:uuid withTimestamp:touch.timestamp phase:UITouchPhaseCancelled location:[touch locationInView:self] pathIndex:(unsigned char)touch.pathIndex inView:self];
    }
    [self touchCancelled:cancelled ?: touch executionContext:context];

    // Edit the text once the keyboard has finished this task.
    dispatch_async(dispatch_get_main_queue(), ^{
        SCPPerform(action);
    });
}

- (void)touchCancelled:(UIKBTouchState *)touch executionContext:(UIKeyboardTaskExecutionContext *)context {
    NSUUID *uuid = [touch touchUUID];
    if (uuid) [gSpaceTouches removeObject:uuid];
    %orig;
}

%end

%hook UIKBTree

// Don't let QuickPath (slide-to-type) start on the space key, otherwise the slide is eaten.
- (BOOL)allowsStartingContinuousPath {
    return SCPIsSpaceKey(self) ? NO : %orig;
}

%end

#pragma mark - Constructor

static BOOL SCPShouldLoad(void) {
    NSString *path = [NSProcessInfo processInfo].arguments.firstObject;
    if (!path.length) return NO;

    NSString *process = path.lastPathComponent;
    if ([path containsString:@".appex/"]) return NO;
    if ([path.lowercaseString containsString:@"fileprovider"]) return NO;
    NSArray<NSString *> *blacklist = @[ @"AdSheet", @"CoreAuthUI", @"InCallService", @"MessagesNotificationViewService" ];
    if ([blacklist containsObject:process]) return NO;

    BOOL isSpringBoard = [process isEqualToString:@"SpringBoard"];
    BOOL isApp = [path containsString:@"/Application/"] || [path containsString:@"/Applications/"];
    return isSpringBoard || isApp;
}

%ctor {
    @autoreleasepool {
        if (!SCPShouldLoad()) return;

        SCPKeyMap = @{
            @"x": @(SCPActionCut),
            @"c": @(SCPActionCopy),
            @"v": @(SCPActionPaste),
            @"a": @(SCPActionSelectAll),
            @"z": @(SCPActionUndo),
            @"y": @(SCPActionRedo),
            @"q": @(SCPActionLineStart),
            @"p": @(SCPActionLineEnd),
            @"b": @(SCPActionDocumentStart),
            @"e": @(SCPActionDocumentEnd),
            @"s": @(SCPActionSelectWord),
            @"h": @(SCPActionMoveLeft),
            @"j": @(SCPActionMoveDown),
            @"k": @(SCPActionMoveUp),
            @"l": @(SCPActionMoveRight),
            @"d": @(SCPActionTranslate),
            @"n": @(SCPActionPreviousWord),
            @"m": @(SCPActionNextWord),
            @"delete": @(SCPActionDeleteWord),
        };

        gSpaceTouches = [NSMutableSet set];
        %init;
    }
}
