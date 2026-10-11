#import <UIKit/UIKit.h>
#import <SpriteKit/SpriteKit.h>
#import <SceneKit/SceneKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreText/CoreText.h>
#include <dlfcn.h>
@interface NSObject (OriginalAPI)
- (id)initWithMain:(id)main msg:(id)msg;
- (id)initWithMain:(id)main;
- (void)resize;
- (void)showRoomChat;
- (void)receiveRoomChat:(NSString *)text from:(NSString *)sender;
@end
static NSDictionary *liveState;
static NSString *displayedRevision;
static NSString *outgoingRevision;
static IMP playAgainOriginal;
static NSString *boundaryError;
static NSString *rejectedRevision;
static NSDictionary *gameRegistry(void){NSData *data=[NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"macpigeon-game-registry" withExtension:@"json"]];return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:@{};}
static NSDictionary *generatedInvitation;
// The live room SDK needs a participant UUID, but no Messages conversation object.
@interface NativeConversation:NSObject
@property(nonatomic,strong)NSUUID *localParticipantIdentifier;
@end
@implementation NativeConversation
@end
static NativeConversation *roomConversation(NSUserDefaults *prefs){
 NSString *saved=[prefs stringForKey:@"crazy_participant_id"];NSUUID *identifier=[[NSUUID alloc]initWithUUIDString:saved];
 if(!identifier){identifier=NSUUID.UUID;[prefs setObject:identifier.UUIDString forKey:@"crazy_participant_id"];}
 NativeConversation *conversation=[NativeConversation new];conversation.localParticipantIdentifier=identifier;return conversation;
}
static void factoryTrack(id object,SEL selector,id event){}
static NSInteger factoryPresentation(id object,SEL selector){return 0;}
static id factorySend(id object,SEL selector,NSArray *items,id image,id caption,id subcaption,BOOL dismiss,BOOL start){NSMutableDictionary *d=[NSMutableDictionary dictionary];for(NSURLQueryItem *q in items)if(q.name && q.value)d[q.name]=q.value;generatedInvitation=d;return nil;}
// Use the original invitation builder without creating a Messages conversation or sending.
static NSDictionary *makeInvitation(id prefs,id menu,NSString *game){
 if(!gameRegistry()[game])return nil;
 Class factory=NSClassFromString(@"MacPigeonInvitationFactory");if(!factory){factory=objc_allocateClassPair(NSClassFromString(@"MessagesViewController"),"MacPigeonInvitationFactory",0);
 class_addMethod(factory,NSSelectorFromString(@"track:"),(IMP)factoryTrack,"v@:@");class_addMethod(factory,NSSelectorFromString(@"presentationStyle"),(IMP)factoryPresentation,"q@:");
 Method send=class_getInstanceMethod(NSClassFromString(@"MessagesViewController"),NSSelectorFromString(@"sendMessage:image:caption:subcaption:dismiss:start:"));class_addMethod(factory,method_getName(send),(IMP)factorySend,method_getTypeEncoding(send));objc_registerClassPair(factory);}
 generatedInvitation=nil;id builder=[factory new];[builder setValue:prefs forKey:@"prefs"];[builder setValue:menu forKey:@"gameVC"];
 [builder setValue:roomConversation(prefs) forKey:@"convo"];
 if(![prefs stringForKey:@"player_id_new"])[prefs setObject:@"macpigeon-local-player-2" forKey:@"player_id_new"];
 ((void(*)(id,SEL,id))objc_msgSend)(builder,NSSelectorFromString(@"requestStart:"),game);
 NSDictionary *result=generatedInvitation;generatedInvitation=nil;return result;
}
static id originalObject(id object,NSString *name){Ivar ivar=class_getInstanceVariable([object class],name.UTF8String);return ivar?object_getIvar(object,ivar):nil;}
static long long originalInteger(id object,NSString *name){Ivar ivar=class_getInstanceVariable([object class],name.UTF8String);if(!ivar)return 0;const char *type=ivar_getTypeEncoding(ivar);const char *p=(const char *)(__bridge void *)object+ivar_getOffset(ivar);switch(type[0]){case 'q':return *(const long long *)p;case 'Q':return *(const unsigned long long *)p;case 'i':return *(const int *)p;case 'I':return *(const unsigned int *)p;default:return 0;}}
static NSURL *support(void){return [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];}
static void save(NSDictionary *d,NSString *name){NSData *data=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil];NSURL *u=[support() URLByAppendingPathComponent:name];[data writeToURL:u atomically:YES];[[NSFileManager defaultManager]setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:u.path error:nil];}
static NSDictionary *readNative(NSString *name){NSURL *u=[support() URLByAppendingPathComponent:name];NSDictionary *attr=[[NSFileManager defaultManager]attributesOfItemAtPath:u.path error:nil];if([attr[NSFileSize] unsignedLongLongValue]>262144)return nil;NSData *d=[NSData dataWithContentsOfURL:u];return d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;}
static BOOL localRestart(NSArray *items){
 if(![liveState[@"mode"]isEqualToString:@"local"] || ![liveState[@"finished"]boolValue] || [liveState[@"expires_at"]doubleValue]<NSDate.date.timeIntervalSince1970)return NO;
 NSMutableDictionary *fields=[NSMutableDictionary dictionary];for(NSURLQueryItem *q in items)if(q.name && q.value)fields[q.name]=q.value;
 NSString *game=fields[@"game"]?:liveState[@"game"];if(!gameRegistry()[game])return NO;
 NSMutableDictionary *options=[liveState[@"initial_options"]isKindOfClass:NSDictionary.class]?[liveState[@"initial_options"]mutableCopy]:[NSMutableDictionary dictionary];if(!options.count)for(NSString *key in @[@"mode",@"size"]){NSString *value=fields[key]?:liveState[@"fields"][key];if([value isKindOfClass:NSString.class])options[key]=value;}
 save(@{@"id":NSUUID.UUID.UUIDString,@"game":game,@"options":options,@"avatar":fields[@"avatar2"]?:fields[@"avatar1"]?:liveState[@"fields"][@"avatar2"]?:@""},@"native-menu-request.json");return YES;
}
static void localPlayAgain(id scene,SEL selector){if(!localRestart(nil))((void(*)(id,SEL))playAgainOriginal)(scene,selector);}
static void captureOutgoing(id scene,SEL selector,NSArray *items,id image,id caption,id subcaption){
 if(![liveState[@"can_play"] boolValue] || [liveState[@"expires_at"] doubleValue]<NSDate.date.timeIntervalSince1970 || !displayedRevision || [outgoingRevision isEqualToString:displayedRevision])return;
 boundaryError=nil;rejectedRevision=nil;
 NSMutableDictionary *fields=[NSMutableDictionary dictionary];for(NSURLQueryItem *q in items)if(q.name && q.value)fields[q.name]=q.value;
 if([fields[@"game"]isEqualToString:@"crazy"]){
  // RESEND shares the existing room through the launcher's invitation confirmation.
  // Live card moves never enter the alternating-turn Messages transport.
  save(@{@"id":NSUUID.UUID.UUIDString,@"game":@"crazy",@"options":@{@"__native":@"1",@"room":fields[@"room"]?:@""},@"avatar":fields[@"avatar2"]?:fields[@"avatar1"]?:@""},@"native-menu-request.json");return;
 }
 // Transport wrapper owns the next message ordinal; original game supplies the replay.
 fields[@"num"]=@([liveState[@"num"]integerValue]+1).stringValue;
 fields[@"sender"]=liveState[@"own_id"]?:@"";fields[@"player"]=@([liveState[@"own_player"]intValue]).stringValue;
 id local=originalObject(scene,@"avatar"),other=originalObject(scene,@"avatar2");
 BOOL won=local && ((int(*)(id,SEL))objc_msgSend)(local,NSSelectorFromString(@"win"));BOOL lost=other && ((int(*)(id,SEL))objc_msgSend)(other,NSSelectorFromString(@"win"));
 long long gameState=originalInteger(scene,@"game_state"),sendWin=originalInteger(scene,@"send_win");
 // Match the original GameScene wrapper, including Golf's explicit result.
 if((gameState>=2 && gameState<=4)||(sendWin>=2 && sendWin<=4)){
  int result=gameState==3?-1:gameState==2?1:0;if(sendWin>=2 && sendWin<=4)result=sendWin==2?1:sendWin==3?-1:0;
  fields[@"winner"]=[NSString stringWithFormat:@"%@|%d",liveState[@"own_id"]?:@"",result];
 }else if(won || lost)fields[@"winner"]=[NSString stringWithFormat:@"%@|%d",liveState[@"own_id"]?:@"",won && lost?0:won?1:-1];
 if([scene respondsToSelector:NSSelectorFromString(@"setMessage_sent:")])((void(*)(id,SEL,BOOL))objc_msgSend)(scene,NSSelectorFromString(@"setMessage_sent:"),YES);
 outgoingRevision=displayedRevision;
 save(@{@"request_id":NSUUID.UUID.UUIDString,@"revision":displayedRevision,@"connection_id":liveState[@"connection_id"]?:@"",@"fields":fields},@"native-request.json");
}
static void captureOutgoingExtended(id scene,SEL selector,NSArray *items,id image,id caption,id subcaption,BOOL dismiss,BOOL start,id transcript){if(!start)captureOutgoing(scene,selector,items,image,caption,subcaption);}
static IMP menuOriginal;
static void unavailableMenuAction(id object,SEL selector){
 id main=[object valueForKey:@"main"];UIViewController *controller=[main valueForKey:@"controller"];
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Unavailable" message:@"Purchases are not supported in MacPigeon." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[controller presentViewController:alert animated:YES completion:nil];
}
static void unavailableStore(id object,SEL selector,NSInteger store){unavailableMenuAction(object,selector);}
static void originalMenu(id controller,SEL selector,NSString *name){
 ((void(*)(id,SEL,id))menuOriginal)(controller,selector,name);
 if([name isEqualToString:@"settings"]){SKScene *scene=[controller valueForKey:@"scene"];for(NSString *key in @[@"restore_button",@"unlock_button"]){SKNode *node=originalObject(scene,key);node.alpha=0.45;((void(*)(id,SEL,SEL))objc_msgSend)(node,NSSelectorFromString(@"setAction:"),NULL);}}
}
static void installBoundary(void){
 Method again=class_getInstanceMethod(NSClassFromString(@"GameScene"),NSSelectorFromString(@"playAgain"));if(again){playAgainOriginal=method_getImplementation(again);method_setImplementation(again,(IMP)localPlayAgain);}
 Method store=class_getInstanceMethod(NSClassFromString(@"GamesViewController"),NSSelectorFromString(@"openStore:"));if(store)method_setImplementation(store,(IMP)unavailableStore);
 Method menu=class_getInstanceMethod(NSClassFromString(@"GamesViewController"),NSSelectorFromString(@"addMenu:"));if(menu){menuOriginal=method_getImplementation(menu);method_setImplementation(menu,(IMP)originalMenu);}
 for(NSString *selector in @[@"buyAvatars",@"restoreAvatars"]){Method method=class_getInstanceMethod(NSClassFromString(@"SettingsScene"),NSSelectorFromString(selector));if(method)method_setImplementation(method,(IMP)unavailableMenuAction);}
Method m=class_getInstanceMethod(NSClassFromString(@"GameScene"),NSSelectorFromString(@"sendMessage:image:caption:subcaption:"));if(m)method_setImplementation(m,(IMP)captureOutgoing);
Method extended=class_getInstanceMethod(NSClassFromString(@"GameScene"),NSSelectorFromString(@"sendMessage:image:caption:subcaption:dismiss:start:transcript:"));if(extended)method_setImplementation(extended,(IMP)captureOutgoingExtended);}
@interface NativeMessage:NSObject
@property(nonatomic,strong) NSURL *URL;
@end
@implementation NativeMessage
- (NSUUID *)senderParticipantIdentifier{return [[NSUUID alloc]initWithUUIDString:@"00000000-0000-0000-0000-000000000002"];}
- (id)layout{return nil;}
@end
static NSDictionary *fields(id message){NSMutableDictionary *d=[NSMutableDictionary dictionary];NSURLComponents *c=[NSURLComponents componentsWithURL:[message URL] resolvingAgainstBaseURL:NO];for(NSURLQueryItem *q in c.queryItems)if(q.name && q.value)d[q.name]=q.value;return d;}
@interface NativeMain:NSObject
@property(nonatomic,weak)UIViewController *controller;
@property(nonatomic,strong)NSUserDefaults *prefs;
@property(nonatomic,copy)NSString *ownID;
@property(nonatomic,assign)int ownPlayer;
@property(nonatomic,assign)BOOL tapped;
@property(nonatomic,assign)BOOL pressed;
@end
@implementation NativeMain
- (id)init{if((self=[super init])){_prefs=[[NSUserDefaults alloc]initWithSuiteName:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".preferences"]];[_prefs setInteger:99999 forKey:@"version"];if(![_prefs boolForKey:@"audio_controls_initialized"]){[_prefs setBool:YES forKey:@"settings_music"];[_prefs setBool:YES forKey:@"settings_sound"];[_prefs setBool:YES forKey:@"audio_controls_initialized"];}[_prefs registerDefaults:@{@"settings_music":@YES,@"settings_sound":@YES}];}return self;}
- (NSArray *)games{return @[@"pool",@"pool2",@"pool3",@"sea",@"crazy",@"golf",@"basketball",@"beer",@"darts",@"archery",@"tanks",@"anagrams",@"hunt",@"wordbites",@"fill",@"connect",@"dots",@"mancala",@"chess",@"checkers",@"reversi",@"renju",@"questions",@"paint",@"shuffle",@"knock"];}
- (UIView *)view{return [[self.controller valueForKey:@"menuOpen"]boolValue]?self.controller.view:([self.controller valueForKey:@"contentView"]?:self.controller.view);}
- (id<UILayoutSupport>)bottomLayoutGuide{return self.controller.bottomLayoutGuide;}
- (id<UILayoutSupport>)topLayoutGuide{return self.controller.topLayoutGuide;}
- (void)removeOlderFiles{}
- (void)menuExpand{}
- (void)menuMinimize{}
- (NSInteger)presentationStyle{return 1;}
- (void)diplayGameSelector{
 UIViewController *controller=self.controller;
 dispatch_async(dispatch_get_main_queue(),^{((void(*)(id,SEL))objc_msgSend)(controller,NSSelectorFromString(@"showMenu"));});
}
- (void)requestPresentationStyle:(NSInteger)style{if(style==0)[self diplayGameSelector];}
- (void)setNeedsUpdateOfHomeIndicatorAutoHidden{}

- (void)requestStart{}
- (void)requestStart:(NSString *)game{
 if([game isEqualToString:@"crazy"] && [liveState[@"mode"]isEqualToString:@"local"]){
  UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Online game" message:@"Crazy 8 uses a live multiplayer room. Switch to Messages play to invite your friends." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self.controller presentViewController:alert animated:YES completion:nil];return;
 }
 if(gameRegistry()[game]){
  @try{if(![self.prefs stringForKey:@"player_id_new"])[self.prefs setObject:@"macpigeon-local-player-2" forKey:@"player_id_new"];
  id menu=[self.controller valueForKey:@"menuController"];NSDictionary *original=makeInvitation(self.prefs,menu,game);if(!original)[NSException raise:@"InvitationSetup" format:@"The original setup did not produce a game. Choose its options and try again."];
  NSString *selected=original[@"game"]?:game;if(!gameRegistry()[selected])[NSException raise:@"InvitationSetup" format:@"This game variant is not available."];
  NSMutableDictionary *options=[original mutableCopy];for(NSString *key in @[@"id",@"game",@"game_name",@"num",@"player",@"player1",@"player2",@"sender",@"avatar1",@"avatar2",@"start",@"caption",@"winner"]) [options removeObjectForKey:key];options[@"__native"]=@"1";
  save(@{@"id":NSUUID.UUID.UUIDString,@"game":selected,@"options":options,@"avatar":[self.prefs stringForKey:@"avatar"]?:@""},@"native-menu-request.json");return;
  }@catch(NSException *e){
   NSString *message=e.reason?:@"Invitation setup failed";save(@{@"error":message},@"native-renderer-status.json");
   UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Cannot start game" message:message preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self.controller presentViewController:alert animated:YES completion:nil];return;
  }
 }
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Game unavailable" message:@"This game is not supported yet." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self.controller presentViewController:alert animated:YES completion:nil];
}
- (id)convo{return roomConversation(self.prefs);}
- (id)gameVC{return self.controller;}
- (void)reloadGame{[self.controller setValue:nil forKey:@"revision"];}
// getPlayer is the local participant, not the actor of the received turn.
- (int)getPlayer:(id)m{NSDictionary *d=fields(m);for(int p=1;p<=2;p++){if([d[[NSString stringWithFormat:@"player%d",p]] isEqualToString:self.ownID])return p;}return self.ownPlayer;}
- (BOOL)isMine:(id)m{return [fields(m)[@"sender"] isEqualToString:self.ownID];}
- (BOOL)isMineString:(NSString *)s{return [s isEqualToString:self.ownID];}
- (BOOL)isMineString:(NSString *)s message:(id)m{return [self isMineString:s];}
- (BOOL)isTranscript{return NO;}
- (NSString *)saveKey:(NSString *)key{return [NSString stringWithFormat:@"game_save_%@%@",key?:@"",[liveState[@"mode"]isEqualToString:@"local"]?[@"_" stringByAppendingString:self.ownID?:@""]:@""];}
- (id)loadSave:(NSString *)key{NSDictionary *value=[self.prefs dictionaryForKey:[self saveKey:key]];if(!value)return nil;NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];return data?[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:NULL error:nil]:nil;}
- (BOOL)saveSave:(NSString *)key what:(id)value{if(![key isKindOfClass:NSString.class] || !value || ![NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListBinaryFormat_v1_0])return NO;[self.prefs setObject:value forKey:[self saveKey:key]];return YES;}
// The standalone host has no advertising presenter.
- (id)playSound:(NSString *)name{return [self playSound:name volume:1.0f];}
- (id)playSound:(NSString *)name volume:(float)volume{
 id scene=[self.controller valueForKey:@"original"];SEL selector=NSSelectorFromString(@"playSound:volume:");
 if([scene respondsToSelector:selector])return ((id(*)(id,SEL,id,float))objc_msgSend)(scene,selector,name,volume);
 selector=NSSelectorFromString(@"playSound:");return [scene respondsToSelector:selector]?((id(*)(id,SEL,id))objc_msgSend)(scene,selector,name):nil;
}
- (void)showAd{}
- (void)hideAd{}
- (void)readyForAd{}
- (void)hideSMS{}
- (void)showSMS{}
- (void)initSMS{}
- (void)focusSMS{[self.controller showRoomChat];}
- (void)receivedSMS:(NSString *)text from:(NSString *)sender{[self.controller receiveRoomChat:text from:sender];}
- (void)updateiCloud{}
- (void)track:(id)event{}
- (void)trackOnce:(id)event{}
- (void)getPrices{}
- (NSDictionary *)store_prices{return @{};}
- (int)consumableGet:(NSString *)key{return 0;}
- (void)consumableAdd:(NSString *)key ammount:(int)amount{}
- (void)consumableConsume:(NSString *)key ammount:(int)amount{}
- (void)storeObserver{}
- (BOOL)iOS11{return YES;}
- (NSDictionary *)game_configs{return @{};}
- (void)doesNotRecognizeSelector:(SEL)selector{save(@{@"host_missing_selector":NSStringFromSelector(selector)},@"native-renderer-status.json");[super doesNotRecognizeSelector:selector];}
@end
@interface NativeVC:UIViewController
@property(nonatomic,strong)NativeMain *host;
@property(nonatomic,strong)UIView *sceneView;
@property(nonatomic,strong)UIAlertController *invitationAlert;
@property(nonatomic,strong)UIAlertAction *invitationSendAction;
@property(nonatomic,strong)UIAlertController *localAlert;
@property(nonatomic,copy)NSString *localRevision;
@property(nonatomic,copy)NSString *invitationID;
@property(nonatomic,strong)UIViewController *menuController;
@property(nonatomic,copy)NSString *viewRequestID;
@property(nonatomic,copy)NSString *connectionID;
@property(nonatomic,assign)BOOL menuOpen;
@property(nonatomic,strong)SKScene *original;
@property(nonatomic,strong)SKView *gameView;
@property(nonatomic,strong)UIView *contentView;
@property(nonatomic,strong)UILabel *status;
@property(nonatomic,strong)NSTimer *timer;
@property(nonatomic,copy)NSString *revision;
@property(nonatomic,copy)NSString *ackID;
@property(nonatomic,strong)UIButton *settingsEntry;
@property(nonatomic,strong)UIButton *helpEntry;
@property(nonatomic,assign)BOOL panelOpen;
@property(nonatomic,copy)NSString *activePanel;
@property(nonatomic,copy)NSString *menuAvatar;
@property(nonatomic,strong)NSMutableArray<NSString *> *roomChat;
@property(nonatomic,copy)NSString *settingsAvatar;
@end
@implementation NativeVC
- (void)receiveRoomChat:(NSString *)text from:(NSString *)sender{
 if(![text isKindOfClass:NSString.class] || text.length>4096)return;
 if(!self.roomChat)self.roomChat=[NSMutableArray array];
 [self.roomChat addObject:[NSString stringWithFormat:@"%@: %@",sender?:@"You",text]];
 while(self.roomChat.count>50)[self.roomChat removeObjectAtIndex:0];
}
- (void)showRoomChat{
 if(![NSStringFromClass(self.original.class)isEqualToString:@"CrazyScene"] || self.presentedViewController)return;
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Room chat" message:self.roomChat.count?[[self.roomChat subarrayWithRange:NSMakeRange(self.roomChat.count>8?self.roomChat.count-8:0,MIN(self.roomChat.count,8))]componentsJoinedByString:@"\n"]:@"Send a message to the players in this room." preferredStyle:UIAlertControllerStyleAlert];
 [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"Message";}];
 [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
 __weak NativeVC *weakSelf=self;
 [alert addAction:[UIAlertAction actionWithTitle:@"Send" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
  NSString *text=alert.textFields.firstObject.text;NativeVC *owner=weakSelf;
  if(text.length && text.length<=4096 && [NSStringFromClass(owner.original.class)isEqualToString:@"CrazyScene"] && [liveState[@"can_play"]boolValue] && [liveState[@"expires_at"]doubleValue]>NSDate.date.timeIntervalSince1970)((void(*)(id,SEL,id))objc_msgSend)(owner.original,NSSelectorFromString(@"sendSMS:"),text);
 }]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)viewDidLoad{
 [super viewDidLoad];self.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;self.view.backgroundColor=UIColor.darkGrayColor;
 [[NSFileManager defaultManager]createDirectoryAtURL:support() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
 NSString *p=[[NSBundle mainBundle]pathForResource:@"ExtensionProbe" ofType:@"bundle"];
 void *h=dlopen([[p stringByAppendingPathComponent:@"ExtensionProbe"]fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
 self.status=[[UILabel alloc]init];self.status.numberOfLines=2;self.status.textColor=UIColor.whiteColor;self.status.backgroundColor=[UIColor colorWithWhite:0 alpha:0.65];self.status.textAlignment=NSTextAlignmentCenter;self.status.font=[UIFont systemFontOfSize:12];self.status.text=h?@"Connecting to MacPigeon…":@"Original extension could not load.";
 self.contentView=[[UIView alloc]initWithFrame:CGRectMake(0,0,375,710)];[self.view addSubview:self.contentView];[self.contentView addSubview:self.status];if(!h)return;installBoundary();
 for(NSString *font in [[NSBundle mainBundle]pathsForResourcesOfType:@"otf" inDirectory:nil])CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:font],kCTFontManagerScopeProcess,NULL);
 self.host=[NativeMain new];self.host.controller=self;id global=((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"Global"),NSSelectorFromString(@"instance"));[global setValue:self.host forKey:@"main"];self.gameView=[[SKView alloc]initWithFrame:self.contentView.bounds];[self.contentView insertSubview:self.gameView belowSubview:self.status];
 // The original setters update the C++ mixer. Applying twice restores the stored
 // boolean while applying both category volumes without recreating any sound.
 SKScene *audio=[[NSClassFromString(@"SettingsScene") alloc]initWithSize:CGSizeMake(375,710)];[audio setValue:self.host forKey:@"main"];
 ((void(*)(id,SEL))objc_msgSend)(audio,NSSelectorFromString(@"setMusic"));((void(*)(id,SEL))objc_msgSend)(audio,NSSelectorFromString(@"setMusic"));
 self.helpEntry=[self entry:@"Help" action:@selector(openHelp)];self.settingsEntry=[self entry:@"Settings" action:@selector(openSettings)];
 if(!readNative(@"native-view.json"))[self showMenu];
 self.timer=[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(poll) userInfo:nil repeats:YES];[self poll];
}
- (void)showMenu{
 if(self.panelOpen)[self openOriginalPanel:[self.activePanel isEqualToString:@"showSettings"]?@"hideSettings":@"hideHelp"];
 [self unloadBoard];
 @try{
 self.menuOpen=YES;self.contentView.hidden=YES;
 if(!self.menuController){self.menuController=[[NSClassFromString(@"GamesViewController")alloc]initWithMain:self.host];[self addChildViewController:self.menuController];[self.view addSubview:self.menuController.view];[self.menuController didMoveToParentViewController:self];}
 self.menuAvatar=[self.host.prefs stringForKey:@"avatar"];self.menuOpen=YES;self.menuController.view.hidden=NO;UIView *back=originalObject(self.menuController,@"back_button");back.isAccessibilityElement=YES;back.accessibilityLabel=@"Back";back.accessibilityTraits=UIAccessibilityTraitButton;self.menuController.view.frame=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);[self.view bringSubviewToFront:self.menuController.view];self.status.hidden=YES;self.settingsEntry.hidden=YES;self.helpEntry.hidden=YES;
 save(@{@"original_menu_loaded":@YES,@"board_attached":@(self.gameView.scene!=nil),@"board_paused":@(self.gameView.paused)},@"native-renderer-status.json");
 }@catch(NSException *e){self.menuOpen=NO;self.contentView.hidden=NO;self.status.hidden=NO;self.status.text=@"Game menu could not open.";save(@{@"menu_error":e.reason?:@"exception"},@"native-renderer-status.json");}
}
- (void)saveMenuAvatar{NSString *avatar=[self.host.prefs stringForKey:@"avatar"];if(self.menuOpen && avatar && ![avatar isEqualToString:self.menuAvatar])[self.host.prefs setBool:YES forKey:@"custom_avatar"];}
- (void)unloadBoard{
 self.roomChat=nil;
 if(self.original)((void(*)(id,SEL))objc_msgSend)(self.original,NSSelectorFromString(@"stopMusic"));
 // Stop the SceneKit delegate before the original engine clears its arrays.
 // Detaching the scene synchronizes with rendering and prevents callbacks into
 // an unloaded Cup Pong/Basketball engine during a menu or player handoff.
 if(self.sceneView){SCNView *view=(SCNView *)self.sceneView;view.delegate=nil;view.playing=NO;view.scene.paused=YES;view.scene=nil;}
 if([self.original respondsToSelector:NSSelectorFromString(@"unload")])((void(*)(id,SEL))objc_msgSend)(self.original,NSSelectorFromString(@"unload"));
 [self.sceneView removeFromSuperview];self.sceneView=nil;
 self.original.paused=YES;self.gameView.userInteractionEnabled=NO;self.sceneView.userInteractionEnabled=NO;
 [self.gameView presentScene:nil];self.gameView.paused=YES;self.original=nil;self.revision=nil;displayedRevision=nil;
}
- (void)leaveMenu{
 [self saveMenuAvatar];
 SKScene *scene=originalObject(self.menuController,@"scene");
 if([scene respondsToSelector:NSSelectorFromString(@"stopMusic")])((void(*)(id,SEL))objc_msgSend)(scene,NSSelectorFromString(@"stopMusic"));
 scene.paused=YES;
 if(self.menuController){
  ((void(*)(id,SEL))objc_msgSend)(self.menuController,NSSelectorFromString(@"removeMenu"));
  [self.menuController willMoveToParentViewController:nil];[self.menuController.view removeFromSuperview];[self.menuController removeFromParentViewController];self.menuController=nil;
 }
 self.menuOpen=NO;self.contentView.hidden=NO;self.gameView.paused=NO;self.status.hidden=NO;self.settingsEntry.hidden=NO;self.helpEntry.hidden=NO;self.revision=nil;
}
- (void)showBoard{[self leaveMenu];[self poll];}
- (UIButton *)entry:(NSString *)name action:(SEL)action{UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];button.accessibilityLabel=name;[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];[self.contentView addSubview:button];return button;}
- (void)placeEntry:(UIButton *)button node:(NSString *)name fallback:(CGPoint)fallback{
 SKNode *node=originalObject(self.original,name);CGPoint point=node?[self.gameView convertPoint:[self.original convertPoint:CGPointZero fromNode:node] fromScene:self.original]:fallback;
 point=[self.contentView convertPoint:point fromView:self.gameView];button.frame=CGRectMake(point.x-24,point.y-24,48,48);
}
- (void)openOriginalPanel:(NSString *)selector{
 BOOL opening=[selector hasPrefix:@"show"];
 if(!self.original || (opening && self.panelOpen))return;
 @try{
  ((void(*)(id,SEL))objc_msgSend)(self.original,NSSelectorFromString(selector));
  self.activePanel=opening?selector:nil;self.panelOpen=opening;self.settingsEntry.enabled=!opening;self.helpEntry.enabled=!opening;
  BOOL settings=[selector isEqualToString:@"showSettings"];
  if(settings || [selector isEqualToString:@"showHelp"]){UIView *screen=originalObject(self.original,settings?@"settingsScreen":@"helpScreen");
   if(settings){
    self.settingsAvatar=[self.host.prefs stringForKey:@"avatar"];
    SKScene *scene=((SKView *)screen).scene;scene.userInteractionEnabled=YES;
    // Keep free avatar editing and audio controls; no purchase/restoration backend.
    for(NSString *name in @[@"restore_button",@"unlock_button"]){SKNode *button=originalObject(scene,name);button.alpha=0.45;((void(*)(id,SEL,SEL))objc_msgSend)(button,NSSelectorFromString(@"setAction:"),NULL);}
   }
   UIImageView *image=originalObject(screen,@"close");if(image){UIButton *close=[UIButton buttonWithType:UIButtonTypeCustom];close.frame=image.frame;close.accessibilityLabel=settings?@"Close Settings":@"Close Help";[close addTarget:self action:settings?@selector(closeSettings):@selector(closeHelp) forControlEvents:UIControlEventTouchUpInside];[screen addSubview:close];}
  }
 }@catch(NSException *error){self.panelOpen=NO;self.settingsEntry.enabled=YES;self.helpEntry.enabled=YES;[self.original removeActionForKey:@"pause_action"];self.original.paused=NO;[originalObject(self.original,@"pause_dark") removeFromSuperview];self.status.text=@"This screen could not open.";save(@{@"panel_error":error.reason?:@"exception",@"panel":selector},@"native-renderer-status.json");}
}
- (void)closeSettings{NSString *avatar=[self.host.prefs stringForKey:@"avatar"];if(avatar && ![avatar isEqualToString:self.settingsAvatar]){[self.host.prefs setBool:YES forKey:@"custom_avatar"];[self.host.prefs synchronize];}[self openOriginalPanel:@"hideSettings"];}
- (void)closeHelp{[self openOriginalPanel:@"hideHelp"];}
- (void)openSettings{[self openOriginalPanel:@"showSettings"];}
- (void)openHelp{[self openOriginalPanel:@"showHelp"];}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator{
 [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
 [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context){self.view.frame=CGRectMake(0,0,size.width,size.height);[self.view setNeedsLayout];[self.view layoutIfNeeded];} completion:nil];
}
- (void)viewDidLayoutSubviews{
 [super viewDidLayoutSubviews];save(@{@"view":NSStringFromCGRect(self.view.bounds),@"window":NSStringFromCGRect(self.view.window.bounds)},@"native-layout.json");CGRect area=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);self.menuController.view.frame=area;
 CGFloat scale=MIN(area.size.width/375.0,area.size.height/710.0);self.contentView.bounds=CGRectMake(0,0,375,710);self.contentView.transform=CGAffineTransformMakeScale(scale,scale);self.contentView.center=CGPointMake(CGRectGetMidX(area),CGRectGetMidY(area));
 self.gameView.frame=self.contentView.bounds;self.status.frame=CGRectMake(0,680,375,30);
 [self placeEntry:self.helpEntry node:@"helpButton" fallback:CGPointMake(28,682)];[self placeEntry:self.settingsEntry node:@"settingsButton" fallback:CGPointMake(347,682)];
 self.view.window.windowScene.sizeRestrictions.minimumSize=CGSizeMake(320,500);self.view.window.windowScene.sizeRestrictions.maximumSize=CGSizeMake(4096,4096);
}
- (void)invitationPhoneChanged:(UITextField *)field{
 NSString *address=[field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"+0123456789 ()-"];
 NSString *digits=[[address componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet]componentsJoinedByString:@""];
 self.invitationSendAction.enabled=[address hasPrefix:@"+"] && [address rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound && digits.length>=7 && digits.length<=15;
}
- (void)pollInvitation{
 NSDictionary *prompt=readNative(@"native-invitation-prompt.json");NSString *identifier=prompt[@"id"],*connection=prompt[@"connection_id"];
 BOOL valid=[identifier isKindOfClass:NSString.class] && [connection isKindOfClass:NSString.class] && [prompt[@"expires_at"]doubleValue]>NSDate.date.timeIntervalSince1970;
 if(self.invitationAlert && (!valid || ![identifier isEqualToString:self.invitationID])){[self.invitationAlert dismissViewControllerAnimated:YES completion:nil];self.invitationAlert=nil;}
 if(!valid || [identifier isEqualToString:self.invitationID] || self.presentedViewController || !self.menuOpen)return;
 self.invitationID=identifier;
 NSString *error=prompt[@"error"];BOOL failed=[error isKindOfClass:NSString.class];
 BOOL needsPhone=[prompt[@"requires_phone"]boolValue];
 NSString *message=failed?error:(needsPhone?[NSString stringWithFormat:@"Enter the iMessage phone number for %@, including +country code, to send this invitation.",prompt[@"target"]?:@"the open conversation"]:[NSString stringWithFormat:@"Send a new game to %@?",prompt[@"target"]?:@"the open conversation"]);
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:failed?@"Cannot start game":prompt[@"title"] message:message preferredStyle:UIAlertControllerStyleAlert];
 if(!failed && needsPhone)[alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"+1 555 555 0123";field.keyboardType=UIKeyboardTypePhonePad;[field addTarget:self action:@selector(invitationPhoneChanged:) forControlEvents:UIControlEventEditingChanged];}];
 self.invitationAlert=alert;
 __weak NativeVC *weakSelf=self;
 if(!failed){self.invitationSendAction=[UIAlertAction actionWithTitle:@"Send invitation" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
  NSString *address=needsPhone?[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
  save(@{@"id":identifier,@"connection_id":connection,@"action":@"send",@"address":address?:@""},@"native-invitation-response.json");weakSelf.invitationAlert=nil;
 }];self.invitationSendAction.enabled=!needsPhone;[alert addAction:self.invitationSendAction];}
 [alert addAction:[UIAlertAction actionWithTitle:failed?@"OK":@"Cancel" style:failed?UIAlertActionStyleDefault:UIAlertActionStyleCancel handler:^(UIAlertAction *action){save(@{@"id":identifier,@"connection_id":connection,@"action":@"cancel"},@"native-invitation-response.json");weakSelf.invitationAlert=nil;}]];
 [self presentViewController:alert animated:YES completion:nil];
}
- (void)pollLocalHandoff:(NSDictionary *)s{
 NSString *revision=s[@"revision"],*connection=s[@"connection_id"];
 BOOL valid=[s[@"mode"]isEqualToString:@"local"] && [s[@"local_handoff"]boolValue] && [revision isKindOfClass:NSString.class] && [s[@"expires_at"]doubleValue]>NSDate.date.timeIntervalSince1970;self.sceneView.userInteractionEnabled=self.gameView.userInteractionEnabled;
 if(self.localAlert && (!valid || ![revision isEqualToString:self.localRevision])){[self.localAlert dismissViewControllerAnimated:NO completion:nil];self.localAlert=nil;self.localRevision=nil;}
 if(!valid)self.localRevision=nil;
 if(!valid || !self.view.window || [revision isEqualToString:self.localRevision] || self.localAlert || self.presentedViewController || self.menuOpen || self.panelOpen)return;
 self.localRevision=revision;
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Player %d’s turn",[s[@"own_player"]intValue]] message:[NSString stringWithFormat:@"Pass the Mac to Player %d, then continue.",[s[@"own_player"]intValue]] preferredStyle:UIAlertControllerStyleAlert];
 self.localAlert=alert;__weak NativeVC *weakSelf=self;
 [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){save(@{@"revision":revision,@"connection_id":connection?:@""},@"native-local-ready.json");weakSelf.localAlert=nil;}]];
 [self presentViewController:alert animated:YES completion:nil];
}
- (void)poll{
 [self pollInvitation];
 NSDictionary *command=readNative(@"native-view.json");
 if([command[@"id"] isKindOfClass:NSString.class] && ![command[@"id"]isEqualToString:self.viewRequestID]){self.viewRequestID=command[@"id"];if([command[@"view"]isEqualToString:@"menu"])[self showMenu];else if([command[@"view"]isEqualToString:@"board"])[self leaveMenu];}
 NSDictionary *s=readNative(@"native-state.json");if(![s isKindOfClass:NSDictionary.class])return;liveState=s;
 if([s[@"connection_id"]isKindOfClass:NSString.class] && ![s[@"connection_id"]isEqualToString:self.connectionID]){
  self.connectionID=s[@"connection_id"];outgoingRevision=nil;boundaryError=nil;rejectedRevision=nil;self.ackID=nil;self.localRevision=nil;
  if(self.localAlert){[self.localAlert dismissViewControllerAnimated:NO completion:nil];self.localAlert=nil;}
  if(self.panelOpen)[self openOriginalPanel:[self.activePanel isEqualToString:@"showSettings"]?@"hideSettings":@"hideHelp"];
  [self unloadBoard];
 }
 if(rejectedRevision && ![rejectedRevision isEqualToString:s[@"revision"]]){boundaryError=nil;rejectedRevision=nil;}
 self.status.text=boundaryError?:s[@"status"]?:@"Connecting…";self.gameView.userInteractionEnabled=!self.menuOpen && ![outgoingRevision isEqualToString:s[@"revision"]] && ([s[@"can_play"] boolValue] || ([s[@"mode"]isEqualToString:@"local"] && [s[@"finished"]boolValue])) && [s[@"expires_at"]doubleValue]>NSDate.date.timeIntervalSince1970;self.sceneView.userInteractionEnabled=self.gameView.userInteractionEnabled;
 NSString *rev=s[@"revision"],*url=s[@"url"];
 // Finish the original modal lifecycle before replacing its owning game scene.
 if(rev && url && !self.menuOpen && !self.panelOpen && ![rev isEqualToString:self.revision]){
 @try{
 self.host.ownID=s[@"own_id"];self.host.ownPlayer=[s[@"own_player"]intValue];
 if([s[@"game"]isEqualToString:@"crazy"] && ![self.host.prefs stringForKey:@"player_name"]){[self.host.prefs setObject:@"Mac Player" forKey:@"player_name"];[self.host.prefs setBool:YES forKey:@"player_name_set"];}
 NSDictionary *messageFields=fields(({NativeMessage *message=[NativeMessage new];message.URL=[NSURL URLWithString:url];message;}));
 NSString *avatar=messageFields[[NSString stringWithFormat:@"avatar%d",self.host.ownPlayer]];if(avatar && ![self.host.prefs boolForKey:@"custom_avatar"])[self.host.prefs setObject:avatar forKey:@"avatar"];[self.host.prefs setObject:self.host.ownID forKey:@"player_id_new"];
 NativeMessage *m=[NativeMessage new];m.URL=[NSURL URLWithString:url];
 [self unloadBoard];
 NSString *game=messageFields[@"game"];NSData *registryData=[NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"macpigeon-game-registry" withExtension:@"json"]];NSDictionary *registry=registryData?[NSJSONSerialization JSONObjectWithData:registryData options:0 error:nil]:nil;NSString *className=registry[game][@"scene"];if(![className isKindOfClass:NSString.class] || ![NSClassFromString(className)isSubclassOfClass:SKScene.class])[NSException raise:@"UnsupportedGame" format:@"Unsupported game"];
 self.gameView.paused=NO;self.original=(SKScene *)[[NSClassFromString(className)alloc]initWithMain:self.host msg:m];
 self.original.size=CGSizeMake(375,710);self.original.scaleMode=SKSceneScaleModeAspectFit;
 // Mirror GameViewController's SceneKit setup before presenting the overlay.
 NSString *viewClass=@{@"basketball":@"BasketballView",@"beer":@"BeerView",@"archery":@"ArcheryView",@"darts":@"DartsView"}[game];
 self.gameView.allowsTransparency=viewClass!=nil;
 if(viewClass){
  self.sceneView=[[NSClassFromString(viewClass)alloc]initWithFrame:self.contentView.bounds];
  if([game isEqualToString:@"beer"] || [game isEqualToString:@"basketball"])((void(*)(id,SEL))objc_msgSend)(self.sceneView,NSSelectorFromString(@"createScene"));
  ((void(*)(id,SEL,id))objc_msgSend)(self.original,NSSelectorFromString(@"setScene3d:"),self.sceneView);
  if([self.sceneView respondsToSelector:NSSelectorFromString(@"setSk_scene:")])((void(*)(id,SEL,id))objc_msgSend)(self.sceneView,NSSelectorFromString(@"setSk_scene:"),self.original);
  self.sceneView.userInteractionEnabled=self.gameView.userInteractionEnabled;[self.contentView insertSubview:self.sceneView belowSubview:self.gameView];
 }
 [self.gameView presentScene:self.original];[self.view setNeedsLayout];self.revision=rev;displayedRevision=rev;
 if([self.host.prefs boolForKey:@"custom_avatar"]){id local=originalObject(self.original,@"avatar");((void(*)(id,SEL,id))objc_msgSend)(local,NSSelectorFromString(@"parseString:"),[self.host.prefs stringForKey:@"avatar"]);}
 save(@{@"original_scene_loaded":@YES,@"scene_view":self.sceneView?NSStringFromClass(self.sceneView.class):@"",@"revision":rev},@"native-renderer-status.json");
 }@catch(NSException *e){self.status.text=@"Original scene needs another host adapter.";save(@{@"error":e.reason?:@"exception"},@"native-renderer-status.json");}
 }
 NSDictionary *ack=readNative(@"native-ack.json");if(ack[@"request_id"] && [ack[@"connection_id"]isEqualToString:s[@"connection_id"]] && [ack[@"revision"]isEqualToString:rev] && ![ack[@"request_id"]isEqualToString:self.ackID]){self.ackID=ack[@"request_id"];self.status.text=ack[@"status"];if(![ack[@"accepted"]boolValue]){boundaryError=ack[@"status"]?:@"Your move was not sent. Try again.";rejectedRevision=rev;outgoingRevision=nil;self.revision=nil;}}
 [self pollLocalHandoff:s];
}
@end
@interface NativeSceneDelegate:UIResponder<UIWindowSceneDelegate>
@property(nonatomic,strong)UIWindow *window;
@end
@implementation NativeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options{
 if(![scene isKindOfClass:UIWindowScene.class])return;
 self.window=[[UIWindow alloc]initWithWindowScene:(UIWindowScene *)scene];self.window.rootViewController=[NativeVC new];[self.window makeKeyAndVisible];
}
@end
@interface NativeDelegate:UIResponder<UIApplicationDelegate>
@end
@implementation NativeDelegate
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o{return YES;}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options{
 UISceneConfiguration *configuration=[[UISceneConfiguration alloc]initWithName:@"Game" sessionRole:session.role];configuration.sceneClass=UIWindowScene.class;configuration.delegateClass=NativeSceneDelegate.class;return configuration;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(NativeDelegate.class));}}
