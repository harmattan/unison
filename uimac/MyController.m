/* Copyright (c) 2003, see file COPYING for details. */

#import "MyController.h"
#import "ReconItem.h"
#include <caml/callback.h>
#include <caml/alloc.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>

extern value Callback_checkexn(value,value);
extern value Callback2_checkexn(value,value,value);

@implementation MyController

static MyController *me; // needed by reloadTable and displayStatus, below

- (void)resizeWindowToSize:(NSSize)newSize
{
    NSRect aFrame;
    
    float newHeight = newSize.height;
    float newWidth = newSize.width;

    aFrame = [NSWindow contentRectForFrameRect:[mainWindow frame] 
                       styleMask:[mainWindow styleMask]];
    
    aFrame.origin.y += aFrame.size.height;
    aFrame.origin.y -= newHeight;
    aFrame.size.height = newHeight;
    aFrame.size.width = newWidth;
    
    aFrame = [NSWindow frameRectForContentRect:aFrame 
                       styleMask:[mainWindow styleMask]];
    
    [mainWindow setFrame:aFrame display:YES animate:YES];
}

- (void)chooseProfiles
{
    [mainWindow setContentView:blankView];
    [self resizeWindowToSize:chooseProfileSize];
    [mainWindow setContentView:chooseProfileView];
    [mainWindow makeFirstResponder:[profileController tableView]]; // profiles get keyboard input
}

- (void)awakeFromNib
{
    me = self;
    // call some ocaml init code.  FIX: Does this occur before ProfileController awakeFromNib?
    value *f = NULL;
    f = caml_named_value("unisonInit0");
    Callback_checkexn(*f, Val_unit);
    caml_reconItems = preconn = Val_int(0); // caml []
    register_global_root(&caml_reconItems);
    register_global_root(&preconn);
    
    // Initialize locals and set up the first window the user will see
    chooseProfileSize = [chooseProfileView frame].size;
    updatesSize = [updatesView frame].size;
    preferencesSize = [preferencesView frame].size;

    // Double clicking in the profile list will open the profile
    [[profileController tableView] setTarget:self];
    [[profileController tableView] setDoubleAction:@selector(openButton:)];

    blankView = [[NSView alloc] init];
    
//    [mainWindow setContentSize:chooseProfileSize];
//    [mainWindow setContentView:chooseProfileView];
    [self chooseProfiles];
}

- (IBAction)createButton:(id)sender
{
    [preferencesController reset];
    [mainWindow setContentView:blankView];
    [self resizeWindowToSize:preferencesSize];
    [mainWindow setContentView:preferencesView];
}

- (IBAction)saveProfileButton:(id)sender
{
    if ([preferencesController validatePrefs]) {
        [profileController initProfiles]; // so the list contains the new profile
        [self chooseProfiles];
    }
}

- (IBAction)cancelProfileButton:(id)sender
{
    [self chooseProfiles];
}

- (void)updateReconItems
{
    [reconItems release];
    reconItems = [[NSMutableArray alloc] init];
    int j = 0;
    int n = Wosize_val(caml_reconItems);
    for (; j<n; j++) {
        [reconItems insertObject:[ReconItem initWithRi:Field(caml_reconItems,j)]
            atIndex:j];
    }
}

- (void)displayDetails:(int)i
{
    if (i >= 0 && i < [reconItems count])
        [detailsTextView setString:[[reconItems objectAtIndex:i] details]];
}
- (void)clearDetails
{
    [detailsTextView setString:@""];
}

- (void)doUpdateThread:(id)whatever
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    preconn = Val_unit; // so old preconn can be garbage collected
    value *f = caml_named_value("unisonInit2");
    caml_reconItems = Callback_checkexn(*f, Val_unit);
    [pool release];
}

- (void)afterUpdate:(NSNotification *)notification
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:NSThreadWillExitNotification
        object:nil];
    [self updateReconItems];
    if ([reconItems count] > 0)
        [tableView selectRow:0 byExtendingSelection:NO];
    
    // label the left and right columns with the roots
    NSTableHeaderCell *left = [[[tableView tableColumns] objectAtIndex:0] headerCell];
    value *f = caml_named_value("unisonFirstRootString");
    [left setObjectValue:[NSString stringWithCString:String_val(Callback_checkexn(*f, Val_unit))]];
    NSTableHeaderCell *right = [[[tableView tableColumns] objectAtIndex:2] headerCell];
    f = caml_named_value("unisonSecondRootString");
    [right setObjectValue:[NSString stringWithCString:String_val(Callback_checkexn(*f, Val_unit))]];
    
    // cause scrollbar to display if necessary
    [tableView reloadData];
    
    // activate menu items
    [tableView setEditable:YES];
}

- (void)afterOpen
{
    NSLog(@"Connected.");
    // move to updates window after clearing it
    [self clearDetails];
    [reconItems release];
    reconItems = nil;
    [updatesText setStringValue:[NSString stringWithFormat:@"Synchronizing profile '%@'",
                                          [profileController selected]]];
    [mainWindow setContentView:blankView];
    [self resizeWindowToSize:updatesSize];
    [mainWindow setContentView:updatesView];
    
    // reconItems table gets keyboard input
    [mainWindow makeFirstResponder:tableView];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(afterUpdate:)
        name:NSThreadWillExitNotification object:nil];
    [NSThread detachNewThreadSelector:@selector(doUpdateThread:)
        toTarget:self withObject:nil];
}

- (IBAction)openButton:(id)sender
{
    NSLog(@"Connecting...");
    // contact server, propagate prefs
    value *f = NULL;
    const char *s = [[profileController selected] cString];
    value caml_s = copy_string(s);
    // possibly slow -- need another thread?  Print "contacting server"
    f = caml_named_value("unisonInit1");
    preconn = Callback_checkexn(*f, caml_s);
    if (preconn == Val_unit) {
        [self afterOpen]; // no prompting required
        return;
    }
    // prompting required
    preconn = Field(preconn,0); // value of Some
    f = caml_named_value("openConnectionPrompt");
    value prompt = Callback_checkexn(*f, preconn);
    if (prompt == Val_unit) {
        // turns out, no prompt needed, but must finish opening connection
        f = caml_named_value("openConnectionEnd");
        Callback_checkexn(*f, preconn);
        [self afterOpen];
        return;
    }
    [self raisePasswordWindow:[NSString stringWithCString:String_val(Field(prompt,0))]];
}

- (IBAction)restartButton:(id)sender
{
    [tableView setEditable:NO];
    [self chooseProfiles];
}

- (void)doSyncThread:(id)whatever
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    value *f = caml_named_value("unisonSynchronize");
    Callback_checkexn(*f, Val_unit);
    [pool release];
}

- (void)afterSync:(NSNotification *)notification
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:NSThreadWillExitNotification
        object:nil];
    int i;
    for (i = 0; i < [reconItems count]; i++) {
        [[reconItems objectAtIndex:i] resetProgress];
    }
    [tableView reloadData];
}

- (IBAction)syncButton:(id)sender
{
    [tableView setEditable:NO];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(afterSync:)
        name:NSThreadWillExitNotification object:nil];
    [NSThread detachNewThreadSelector:@selector(doSyncThread:)
        toTarget:self withObject:nil];
}

- (void)updateTableView:(int)i
{
    [[reconItems objectAtIndex:i] resetProgress];
    [tableView reloadData]; // FIX: can we redisplay just row i?
}

// A function called from ocaml
CAMLprim value reloadTable(value row)
{
    int i = Int_val(row);
    [me updateTableView:i]; // we need 'me' to access its instance variables
    return Val_unit;
}

- (int)numberOfRowsInTableView:(NSTableView *)aTableView
{
    if (!reconItems) return 0;
    else return [reconItems count];
}

- (id)tableView:(NSTableView *)aTableView
    objectValueForTableColumn:(NSTableColumn *)aTableColumn
    row:(int)rowIndex
{
    if (!reconItems) {
        return @"[internal error]";
    }
    if (rowIndex >= 0 && rowIndex < [reconItems count]) {
        NSString *identifier = [aTableColumn identifier];
        ReconItem *ri = [reconItems objectAtIndex:rowIndex];
        NSString *s = [ri valueForKey:identifier];
        return s;
    }
    else return @"[internal error!]";
}
- (void)tableViewSelectionDidChange:(NSNotification *)note
{
    int n = [tableView numberOfSelectedRows];
    if (n == 1) [self displayDetails:[tableView selectedRow]];
    else [self clearDetails];
}

- (void)raisePasswordWindow:(NSString *)prompt
{
    // FIX: some prompts don't ask for password, need to look at it
    NSLog(@"Got the prompt: '%@'",prompt);
    value *f = caml_named_value("unisonPasswordMsg");
    value v = Callback_checkexn(*f, copy_string([prompt cString]));
    if (v == Val_true) {
        [NSApp beginSheet:passwordWindow
            modalForWindow:mainWindow
            modalDelegate:nil
            didEndSelector:nil
            contextInfo:nil];
        return;
    }
    f = caml_named_value("unisonAuthenticityMsg");
    v = Callback_checkexn(*f, copy_string([prompt cString]));
    if (v == Val_true) {
        int i = NSRunAlertPanel(@"New host",prompt,@"Yes",@"No",nil);
        if (i == NSAlertDefaultReturn) {
            f = caml_named_value("openConnectionReply");
            Callback2_checkexn(*f, preconn, copy_string("yes"));
            f = caml_named_value("openConnectionPrompt");
            value prompt = Callback_checkexn(*f, preconn);
            if (prompt == Val_unit) {
                // all done with prompts, finish opening connection
                f = caml_named_value("openConnectionEnd");
                Callback_checkexn(*f, preconn);
                [self afterOpen];
                return;
            }
            else {
                [self raisePasswordWindow:[NSString stringWithCString:String_val(Field(prompt,0))]];
                return;
            }
        }
        if (i == NSAlertAlternateReturn) {
            f = caml_named_value("openConnectionCancel");
            Callback_checkexn(*f, preconn);
            return;
        }
        else {
            NSLog(@"Unrecognized response '%d' from NSRunAlertPanel",i);
            f = caml_named_value("openConnectionCancel");
            Callback_checkexn(*f, preconn);
            return;
        }
    }
    NSLog(@"Unrecognized message from ssh: %@",prompt);
    f = caml_named_value("openConnectionCancel");
    Callback_checkexn(*f, preconn);
}
// The password window will invoke this when Enter occurs, b/c we
// are the delegate.
- (void)controlTextDidEndEditing:(NSNotification *)notification
{
    NSNumber *reason = [[notification userInfo] objectForKey:@"NSTextMovement"];
    int code = [reason intValue];
    if (code == NSReturnTextMovement)
        [self endPasswordWindow:self];    
}
// Or, the Continue button will invoke this when clicked
- (IBAction)endPasswordWindow:(id)sender
{
    [passwordWindow orderOut:self];
    [NSApp endSheet:passwordWindow];
    if ([sender isEqualTo:passwordCancelButton]) {
        value *f = caml_named_value("openConnectionCancel");
        Callback_checkexn(*f, preconn);
       return;
    }
    NSString *password = [passwordText stringValue];
    value *f = NULL;
    const char *s = [password cString];
    value caml_s = copy_string(s);
    f = caml_named_value("openConnectionReply");
    Callback2_checkexn(*f, preconn, caml_s);
    f = caml_named_value("openConnectionPrompt");
    value prompt = Callback_checkexn(*f, preconn);
    if (prompt == Val_unit) {
        // all done with prompts, finish opening connection
        f = caml_named_value("openConnectionEnd");
        Callback_checkexn(*f, preconn);
        [self afterOpen];
    }
    else [self raisePasswordWindow:[NSString stringWithCString:String_val(Field(prompt,0))]];
}

- (NSMutableArray *)reconItems // used in ReconTableView only
{
    return reconItems;
}

- (int)updateForIgnore:(int)i
{
    value *f = caml_named_value("unisonUpdateForIgnore");
    int j = Int_val(Callback_checkexn(*f,Val_int(i)));
    f = caml_named_value("unisonState");
    caml_reconItems = Callback_checkexn(*f, Val_unit);
    [self updateReconItems];
    return j;
}

- (void)statusTextSet:(NSString *)s {
    [statusText setStringValue:s];
}

// A function called from ocaml
CAMLprim value displayStatus(value s)
{
    [me statusTextSet:[NSString stringWithCString:String_val(s)]];
//    NSLog(@"dS: %s",String_val(s));
    return Val_unit;
}

@end