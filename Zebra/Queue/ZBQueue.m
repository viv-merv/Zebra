//
//  ZBQueue.m
//  Zebra
//
//  Created by Wilson Styres on 1/29/19.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "ZBQueue.h"

#import "ZBQueueViewController.h"

#import <ZBAppDelegate.h>
#import <ZBDevice.h>
#import <Console/ZBConsoleViewController.h>
#import <Downloads/ZBDownloadManager.h>
#import <Tabs/ZBTabBarController.h>
#import <Tabs/Packages/Helpers/ZBPackage.h>

@interface ZBQueue () {
    NSMutableArray *installQueue;
    NSMutableArray *removeQueue;
    NSMutableArray *reinstallQueue;
    NSMutableArray *upgradeQueue;
    NSMutableArray *downgradeQueue;
    NSMutableArray *dependencyQueue;
    NSMutableArray *conflictQueue;
    NSMutableArray *packagesToDownload;
    
    NSMutableArray <id <ZBQueueDelegate>> *delegates;
    ZBDownloadManager *downloadManager;
}
@end

@implementation ZBQueue

#pragma mark - Initializers

+ (instancetype)sharedQueue {
    static ZBQueue *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [ZBQueue new];
    });
    return instance;
}

- (id)init {
    self = [super init];
    
    if (self) {
        installQueue = [NSMutableArray new];
        removeQueue = [NSMutableArray new];
        reinstallQueue = [NSMutableArray new];
        upgradeQueue = [NSMutableArray new];
        downgradeQueue = [NSMutableArray new];
        dependencyQueue = [NSMutableArray new];
        conflictQueue = [NSMutableArray new];
        packagesToDownload = [NSMutableArray new];
        
        _controller = [[ZBQueueViewController alloc] init];
        [self addDelegate:_controller];
        
        downloadManager = [[ZBDownloadManager alloc] initWithDownloadDelegate:self];
    }
    
    return self;
}

#pragma mark - Properties

- (unsigned long long)count {
    return installQueue.count + removeQueue.count + reinstallQueue.count + upgradeQueue.count + downgradeQueue.count + dependencyQueue.count + conflictQueue.count;
}

- (NSArray <NSArray <ZBPackage *> *> *)packages {
    NSMutableArray *packages = [NSMutableArray new];
    
    packages[ZBQueueTypeInstall - 1] = installQueue;
    packages[ZBQueueTypeRemove - 1] = removeQueue;
    packages[ZBQueueTypeReinstall - 1] = reinstallQueue;
    packages[ZBQueueTypeUpgrade - 1] = upgradeQueue;
    packages[ZBQueueTypeDowngrade - 1] = downgradeQueue;
    
    return packages;
}

- (NSArray <NSArray *> *)commands {
    NSMutableArray *commands = [NSMutableArray new];
    
    NSMutableArray *removeArguments = [NSMutableArray arrayWithObject:@"-r"];
    for (ZBPackage *package in [removeQueue arrayByAddingObjectsFromArray:conflictQueue]) {
        [removeArguments addObject:package.identifier];
    }
    if (removeArguments.count > 1) {
        ZBCommand *removeCommand = [[ZBCommand alloc] init];
        [removeCommand setCommand:@"/usr/bin/dpkg"];
        [removeCommand setArguments:removeArguments];
        [removeCommand setAsRoot:YES];
        [commands addObject:@[@(ZBStageRemove), removeCommand]];
    }
    
    NSMutableArray *installArguments = [NSMutableArray arrayWithObject:@"-i"];
    for (ZBPackage *package in [installQueue arrayByAddingObjectsFromArray:dependencyQueue]) {
        [installArguments addObject:package.debPath];
    }
    if (installArguments.count > 1) {
        ZBCommand *installCommand = [[ZBCommand alloc] init];
        [installCommand setCommand:@"/usr/bin/dpkg"];
        [installCommand setArguments:removeArguments];
        [installCommand setAsRoot:YES];
        [commands addObject:@[@(ZBStageInstall), installCommand]];
    }
    
    NSMutableArray *reinstallArguments = [NSMutableArray arrayWithObject:@"-i"];
    for (ZBPackage *package in reinstallQueue) {
        [reinstallArguments addObject:package.debPath];
    }
    if (reinstallArguments.count > 1) {
        ZBCommand *reinstallCommand = [[ZBCommand alloc] init];
        [reinstallCommand setCommand:@"/usr/bin/dpkg"];
        [reinstallCommand setArguments:reinstallArguments];
        [reinstallCommand setAsRoot:YES];
        [commands addObject:@[@(ZBStageReinstall), reinstallCommand]];
    }
    
    NSMutableArray *upgradeArguments = [NSMutableArray arrayWithObject:@"-i"];
    for (ZBPackage *package in upgradeQueue) {
        [upgradeArguments addObject:package.debPath];
    }
    if (upgradeArguments.count > 1) {
        ZBCommand *upgradeCommand = [[ZBCommand alloc] init];
        [upgradeCommand setCommand:@"/usr/bin/dpkg"];
        [upgradeCommand setArguments:upgradeArguments];
        [upgradeCommand setAsRoot:YES];
        [commands addObject:@[@(ZBStageUpgrade), upgradeCommand]];
    }
    
    NSMutableArray *downgradeArugments = [NSMutableArray arrayWithObject:@"-i"];
    for (ZBPackage *package in downgradeQueue) {
        [downgradeArugments addObject:package.debPath];
    }
    if (downgradeArugments.count > 1) {
        ZBCommand *downgradeCommand = [[ZBCommand alloc] init];
        [downgradeCommand setCommand:@"/usr/bin/dpkg"];
        [downgradeCommand setArguments:downgradeArugments];
        [downgradeCommand setAsRoot:YES];
        [commands addObject:@[@(ZBStageDowngrade), downgradeCommand]];
    }
    
    return commands;
}

#pragma mark - Delegate Management

- (void)addDelegate:(id <ZBQueueDelegate>)delegate {
    if (!delegates) delegates = [NSMutableArray new];
    
    [delegates addObject:delegate];
}

- (void)removeDelegate:(id <ZBQueueDelegate>)delegate {
    if (!delegates) return;
    
    [delegates removeObject:delegate];
}

#pragma mark - Queue Management

- (void)addPackage:(ZBPackage *)package toQueue:(ZBQueueType)queue {
    if (queue == ZBQueueTypeNone) return;
    
    NSMutableArray *array = [self queueForType:queue];
    if (![array containsObject:package]) {
        [array addObject:package];
    }
    
    if (queue == ZBQueueTypeInstall || queue == ZBQueueTypeReinstall || queue == ZBQueueTypeUpgrade || queue == ZBQueueTypeDowngrade || queue == ZBQueueTypeDependency) {
        if (![package debPath]) { // Packages that are already downloaded will have debPath set
            [packagesToDownload addObject:package];
            if ([ZBDevice connectionType] == ZBConnectionTypeWiFi) [self->downloadManager downloadPackages:@[package]];
        }
    }
    
    [self bulkPackages:@[package] addedToQueue:queue];
}

- (void)removePackage:(ZBPackage *)package {
    [self removePackage:package fromQueue:[self locate:package]];
}

- (void)removePackage:(ZBPackage *)package fromQueue:(ZBQueueType)queue {
    if (queue == ZBQueueTypeNone) return;
    
    switch(queue) {
        case ZBQueueTypeInstall:
        case ZBQueueTypeReinstall:
        case ZBQueueTypeUpgrade:
        case ZBQueueTypeDowngrade:
        case ZBQueueTypeDependency:
            [packagesToDownload removeObject:package];
        case ZBQueueTypeRemove:
        case ZBQueueTypeConflict:
            [[self queueForType:queue] removeObject:package];
        default:
            break;
    }
    
    [self bulkPackages:@[package] removedFromQueue:queue];
}

- (ZBQueueType)locate:(ZBPackage *)package {
    for (ZBQueueType queue = ZBQueueTypeInstall; queue <= ZBQueueTypeDependency; queue++) {
        if ([[self queueForType:queue] containsObject:package]) {
            return queue;
        }
    }
    return ZBQueueTypeNone;
}

- (BOOL)contains:(ZBPackage *)package inQueue:(ZBQueueType)queue {
    return [[self queueForType:queue] containsObject:package];
}

- (void)removeAllPackages {
    [installQueue removeAllObjects];
    [removeQueue removeAllObjects];
    [reinstallQueue removeAllObjects];
    [upgradeQueue removeAllObjects];
    [downgradeQueue removeAllObjects];
    [dependencyQueue removeAllObjects];
    [conflictQueue removeAllObjects];
    
    [packagesToDownload removeAllObjects];
}

- (NSArray <ZBPackage *> *)packagesToRemove {
    return [removeQueue arrayByAddingObjectsFromArray:conflictQueue];
}

- (NSArray <ZBPackage *> *)packagesToInstall {
    NSMutableArray *packagesToInstall = [NSMutableArray new];
    
    [packagesToInstall addObjectsFromArray:installQueue];
    [packagesToInstall addObjectsFromArray:reinstallQueue];
    [packagesToInstall addObjectsFromArray:upgradeQueue];
    [packagesToInstall addObjectsFromArray:downgradeQueue];
    [packagesToInstall addObjectsFromArray:dependencyQueue];
    
    return packagesToInstall;
}

#pragma mark - Queue Delegate

- (void)bulkPackages:(NSArray <ZBPackage *> *)packages addedToQueue:(ZBQueueType)queue {
    if (!queue) return;
    
    for (NSObject <ZBQueueDelegate> *delegate in delegates) {
        [delegate packages:packages addedToQueue:queue];
    }
    
    [[ZBAppDelegate tabBarController] presentPopupBar];
}

- (void)bulkPackages:(NSArray <ZBPackage *> *)packages removedFromQueue:(ZBQueueType)queue {
    if (!queue) return;
    
    for (NSObject <ZBQueueDelegate> *delegate in delegates) {
        [delegate packages:packages removedFromQueue:queue];
    }
    
    [[ZBAppDelegate tabBarController] presentPopupBar];
}

- (void)bulkStartedDownloadForPackage:(ZBPackage *)package inQueue:(ZBQueueType)queue {
    if (!queue) return;
    
    for (NSObject <ZBQueueDelegate> *delegate in delegates) {
        if ([delegate respondsToSelector:@selector(startedDownloadForPackage:inQueue:)]) {
            [delegate startedDownloadForPackage:package inQueue:queue];
        }
    }
}

- (void)bulkDownloadProgressUpdate:(CGFloat)progress forPackage:(ZBPackage *)package inQueue:(ZBQueueType)queue {
    if (!queue) return;
    
    for (NSObject <ZBQueueDelegate> *delegate in delegates) {
        if ([delegate respondsToSelector:@selector(downloadProgressUpdate:forPackage:inQueue:)]) {
            [delegate downloadProgressUpdate:progress forPackage:package inQueue:queue];
        }
    }
}

- (void)bulkFinishedDownloadForPackage:(ZBPackage *)package inQueue:(ZBQueueType)queue error:(NSError *)error {
    if (!queue) return;
    
    for (NSObject <ZBQueueDelegate> *delegate in delegates) {
        if ([delegate respondsToSelector:@selector(finishedDownloadForPackage:inQueue:error:)]) {
            [delegate finishedDownloadForPackage:package inQueue:queue error:error];
        }
    }
}

#pragma mark - Download Delegate

- (void)startedDownloads {
    [self.controller lockConfirmButton];
}

- (void)finishedAllDownloads {
    [self.controller unlockConfirmButton];
}

- (void)startedPackageDownload:(ZBPackage *)package {
    ZBQueueType queueType = [self locate:package];
    [self bulkStartedDownloadForPackage:package inQueue:queueType];
}

- (void)progressUpdate:(CGFloat)progress forPackage:(ZBPackage *)package {
    ZBQueueType queueType = [self locate:package];
    [self bulkDownloadProgressUpdate:progress forPackage:package inQueue:queueType];
}

- (void)finishedPackageDownload:(ZBPackage *)package withError:(NSError *_Nullable)error {
    ZBQueueType queueType = [self locate:package];
    [self bulkFinishedDownloadForPackage:package inQueue:queueType error:error];
    [packagesToDownload removeObject:package];
}

#pragma mark - Helper Methods

- (NSMutableArray *)queueForType:(ZBQueueType)queue {
    switch(queue) {
        case ZBQueueTypeInstall:
            return installQueue;
        case ZBQueueTypeRemove:
            return removeQueue;
        case ZBQueueTypeReinstall:
            return reinstallQueue;
        case ZBQueueTypeUpgrade:
            return upgradeQueue;
        case ZBQueueTypeDowngrade:
            return downgradeQueue;
        case ZBQueueTypeDependency:
            return dependencyQueue;
        case ZBQueueTypeConflict:
            return conflictQueue;
        default:
            return NULL;
    }
}

- (NSString *)displayableNameForQueueType:(ZBQueueType)queue {
    switch (queue) {
        case ZBQueueTypeInstall:
        case ZBQueueTypeDependency:
            return NSLocalizedString(@"Install", @"");
        case ZBQueueTypeConflict:
        case ZBQueueTypeRemove:
            return NSLocalizedString(@"Remove", @"");
        case ZBQueueTypeReinstall:
            return NSLocalizedString(@"Reinstall", @"");
        case ZBQueueTypeUpgrade:
            return NSLocalizedString(@"Upgrade", @"");
        case ZBQueueTypeDowngrade:
            return NSLocalizedString(@"Downgrade", @"");
        default:
            return NULL;
    }
}

+ (UIColor *)colorForQueueType:(ZBQueueType)queue {
    switch (queue) {
        case ZBQueueTypeDependency:
        case ZBQueueTypeInstall:
            return [UIColor systemTealColor];
        case ZBQueueTypeConflict:
        case ZBQueueTypeRemove:
            return [UIColor systemPinkColor];
        case ZBQueueTypeReinstall:
            return [UIColor systemOrangeColor];
        case ZBQueueTypeUpgrade:
            return [UIColor systemBlueColor];
        case ZBQueueTypeDowngrade:
            return [UIColor systemPurpleColor];
        default:
            return nil;
    }
}

@end
