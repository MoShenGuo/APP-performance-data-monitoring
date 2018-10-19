//
//  TDPerformanceDataManager.m
//  TuanDaiV4
//
//  Created by guoxiaoliang on 2018/6/28.
//  Copyright © 2018 Dee. All rights reserved.
//性能获取数据管理者

#import "TDPerformanceDataManager.h"
#import "TDPerformanceDataModel.h"
#import "TDGlobalTimer.h"
#import "TDDispatchAsync.h"
#import "TDPerformanceMonitor.h"
#import "TDFPSMonitor.h"
#import <HLAppMonitor/HLAppMonitor-Swift.h>
#import "TDFluencyStackMonitor.h"
#import <mach/mach.h>
#import <mach/task_info.h>
#import "TDNetworkTrafficManager.h"

//#import "性能测试/Network/TDNetFlowDataSource.h"
@interface TDPerformanceDataManager () <NetworkEyeDelegate,LeakEyeDelegate,CrashEyeDelegate,ANREyeDelegate,TDFPSMonitorDelegate>
{
    LeakEye *leakEye;
    ANREye *anrEye;
    //开始时间
    long long startTime;
    //app启动时间
    NSTimeInterval appStartupTime;

}

@end
static uint64_t loadTime;
static uint64_t applicationRespondedTime = -1;
static mach_timebase_info_data_t timebaseInfo;
static inline NSTimeInterval MachTimeToSeconds(uint64_t machTime) {
    return ((machTime / 1e9) * timebaseInfo.numer) / timebaseInfo.denom;
}
static long logNum = 1;
static long fileNum = 1;

@implementation TDPerformanceDataManager

static inline dispatch_queue_t td_log_IO_queue() {
    static dispatch_queue_t td_log_IO_queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        td_log_IO_queue = dispatch_queue_create("com.tuandaiguo.td_log_IO_queue", NULL);
    });
    return td_log_IO_queue;
}
/*
 因为类的+ load方法在main函数执行之前调用，所以我们可以在+ load方法记录开始时间，同时监听UIApplicationDidFinishLaunchingNotification通知，收到通知时将时间相减作为应用启动时间，这样做有一个好处，不需要侵入到业务方的main函数去记录开始时间点。
 */
+ (void)load {
    loadTime = mach_absolute_time();
    mach_timebase_info(&timebaseInfo);
  //  __weak typeof(self) weakSelf = self;
    @autoreleasepool {
        __block id obs;
        obs = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                                object:nil queue:nil
                                                            usingBlock:^(NSNotification *note) {
                                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                                    
                                                                    applicationRespondedTime = mach_absolute_time();
                                                                    NSLog(@"StartupMeasurer: it took %f seconds until the app could respond to user interaction.", MachTimeToSeconds(applicationRespondedTime - loadTime));
                                                                    NSString *appStartupTime =  [[TDPerformanceDataManager sharedInstance] getStringAppStartupTime:MachTimeToSeconds(applicationRespondedTime - loadTime)];
                                                                    [[TDPerformanceDataManager sharedInstance] normalDataStrAppendwith:appStartupTime];
                                                                });
                                                                [[NSNotificationCenter defaultCenter] removeObserver:obs];
                                                            }];
    }
}
+ (instancetype)sharedInstance
{
    static TDPerformanceDataManager * instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TDPerformanceDataManager alloc] init];
    });
    return instance;
}

#pragma mark - Private
- (NSString *)createFilePath {
    static NSString * const kLoggerDatabaseFileName = @"app_logger";
    NSString * filePath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).lastObject stringByAppendingPathComponent: kLoggerDatabaseFileName];
    NSFileManager * manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath: filePath]) {
        [manager createDirectoryAtPath: filePath withIntermediateDirectories: YES attributes: nil error: nil];
        NSLog(@"path=%@",filePath);
    }
    return filePath;
}
static NSString * td_resource_recordDataIntervalTime_callback_key;

/**
 定时将数据字符串写入沙盒文件

 @param intervaTime 上传文件时间间隔,basicTime 基本性能数据获取间隔时间
 */
- (void)startRecordDataIntervalTime: (NSInteger)intervaTime withBasicTime:(NSInteger)basicTime {
    self ->startTime = [self currentTime];
    //监控主线程卡顿
    
    //开启fps监控
    [[TDFPSMonitor sharedMonitor]startMonitoring];
    //开启fps检测
    [TDFPSMonitor sharedMonitor].delegate = self;
    self.isStartCasch = YES;
    [self clearTxt];
    //第一次先记录APP基础信息
    [self getAppBaseInfo];
    //开启网络流量监控
    //[NetworkEye addWithObserver:self];
    //开启网络监控
    [TDNetworkTrafficManager start];
    //开启内存泄漏检测,这个第三方有问题,会导致有的控制器viewDidLoad提前调用导致数据不准确
//    self->leakEye = [[LeakEye alloc] init];
//    self->leakEye.delegate = self;
//    [self->leakEye open];
    //开启奔溃检测
    [CrashEye addWithDelegate:self];
    //开启anrEye
    self->anrEye = [[ANREye alloc] init];
    self->anrEye.delegate = self;
    [self->anrEye openWith:1];
    
     //基本性能数据获取定时器
    [self startBasicResourceDataTime:basicTime];
   // [[TDFluencyStackMonitor sharedInstance]startWithThresholdTime:200];
    if (td_resource_recordDataIntervalTime_callback_key != nil) {return;}
    //设置定时器间隔
    [TDGlobalTimer setUploadCallbackInterval:intervaTime];
    //监听数据
    __weak typeof(self) weakSelf = self;
    td_resource_recordDataIntervalTime_callback_key = [[TDGlobalTimer uploadRegisterTimerCallback: ^{
        dispatch_async(td_log_IO_queue(), ^{
            //将String写入文件
            
            //结束时间
            long long curt = [self currentTime];
            NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
            [weakSelf getStringResourceDataTime:currntime withStartOrEndTime:currntime withIsStartTime:NO];
            NSData *normalData = [weakSelf.normalDataStr dataUsingEncoding:NSUTF8StringEncoding];
            [weakSelf writeToFileWith:normalData];
    
        });
    }] copy];
}

//定时将数据字符串写入沙盒文件 兼容之前写main分支代码
- (void)startToCollectPerformanceData {
    //默认数据设置60s上传文件间隔,1s获取基本性能数据间隔
    [[TDPerformanceDataManager sharedInstance]startRecordDataIntervalTime:60 withBasicTime:1];
}
// 文件写入操作
- (void)writeToFileWith:(NSData *)data {//cd/Users/apple/Desktop/performanceData/applog
    NSString * filePath = [self createFilePath];//@"/Users/mobileserver/Desktop/performanceData/applog"
    NSString *fileDicPath = [filePath stringByAppendingPathComponent:@"appLogIOS.txt"];
    // NSString *fileDicPath = [NSString stringWithFormat:@"/Users/mobileserver/Desktop/applog.txt"];
    if (fileNum == 1) {
        fileNum += 1;
        [[NSData new] writeToFile:fileDicPath atomically:YES];
    }
    // 4.创建文件对接对象
    NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:fileDicPath];
    //找到并定位到outFile的末尾位置(在此后追加文件)
    [handle seekToEndOfFile];
    [handle writeData:data];
    //关闭读写文件
    [handle closeFile];
    [self clearCache];
}
//结束写入数据
- (void)endWriteData {
    
    if (!self.normalDataStr || [self.normalDataStr isEqualToString:@""]) {//如果为空值 或者为nil 就不做此操作
        return;
    }
    //下面就一定有值
      __weak typeof(self) weakSelf = self;
    dispatch_async(td_log_IO_queue(), ^{
        //将String写入文件
        //结束时间
        long long curt = [self currentTime];
        NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
        [weakSelf getStringResourceDataTime:currntime withStartOrEndTime:currntime withIsStartTime:NO];
        NSData *normalData = [weakSelf.normalDataStr dataUsingEncoding:NSUTF8StringEncoding];
        [weakSelf writeToFileWith:normalData];
        
    });
}
- (void)normalDataStrAppendwith:(NSString*)str {
    dispatch_semaphore_t sema = dispatch_semaphore_create(1);
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    [self.normalDataStr appendString:str];
    dispatch_semaphore_signal(sema);
}

//logNum加1
- (void)logNumAddOne {
    dispatch_semaphore_t sema = dispatch_semaphore_create(1);
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    logNum += 1;
    dispatch_semaphore_signal(sema);
}

//清空txt文件
- (void)clearTxt {
    NSString * filePath = [self createFilePath];//@"
    NSString *fileDicPath = [filePath stringByAppendingPathComponent:@"appLogIOS.txt"];
    // 4.创建文件对接对象
    NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:fileDicPath];
    [handle truncateFileAtOffset:0];
    
}
//清空缓存
- (void)clearCache {
    self.normalDataStr = [[NSMutableString alloc] initWithString:@""];
    //清空流量
    [[TDNetFlowDataSource shareInstance] clear];
}
//获取app基本信息数据
- (void)getAppBaseInfo {
    if (logNum != 1) {
        return;
    }
    NSString * bid = [[NSBundle mainBundle]bundleIdentifier];
    NSString * appName = [[[NSBundle mainBundle]infoDictionary] objectForKey:@"CFBundleDisplayName"];
    NSString * appVersion = [[[NSBundle mainBundle]infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    NSString * deviceVersion = [UIDevice currentDevice].systemVersion;
    NSString * deviceName = [UIDevice currentDevice].systemName;
    //开始监控时间传给gt,一开始取出时间
    NSString *currntime = [NSString stringWithFormat:@"%lld",self ->startTime];
    NSString * appInfo = [self getStringAppBaseDataTime:currntime withBundleId:bid withAppName:appName withAppVersion:appVersion withDeviceVersion:deviceVersion withDeviceName:deviceName];
    [self normalDataStrAppendwith:appInfo];
}

//获取app基本性能数据
static NSString * td_resource_monitorData_callback_key;
- (void)startBasicResourceDataTime:(NSInteger)intervaTime {
    if (!self.isStartCasch) {
        return;
    }
    if (td_resource_monitorData_callback_key != nil) { return; }
    
    //设置定时器间隔
    [TDGlobalTimer setCallbackInterval:intervaTime];
  __weak typeof(self) weakSelf = self;
    
    td_resource_monitorData_callback_key = [[TDGlobalTimer registerTimerCallback: ^{
        long long curt = [self currentTime];
        NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
        //fps
        double fps = [[TDFPSMonitor sharedMonitor] getFPS];
        NSString *fpsStr = [NSString stringWithFormat:@"%d",(int)fps];
        //内存
        double appRam = [[Memory applicationUsage][0] doubleValue];
        NSString *appRamStr = [NSString stringWithFormat:@"%.1f",appRam];
        double activeRam = [[Memory systemUsage][1] doubleValue];
        double inactiveRam = [[Memory systemUsage][2] doubleValue];
        double wiredRam = [[Memory systemUsage][3] doubleValue];
        double totleSysRam = [[Memory systemUsage][5] doubleValue];
        double sysRamPercent = ((activeRam + inactiveRam + wiredRam)/totleSysRam) *100;
        NSString *sysRamPercentStr = [NSString stringWithFormat:@"%.1f",sysRamPercent];
        //CPU
        double appCpu = [CPU applicationUsage];//[[TDPerformanceMonitor sharedInstance] getCpuUsage]
        NSString *appCpuStr = [NSString stringWithFormat:@"%.1f",appCpu];
        NSString *sysCpu = [CPU systemUsage][0];
        NSString *userCpu = [CPU systemUsage][1];
        NSString *niceCpu = [CPU systemUsage][3] ;
        double systemCpu = sysCpu.doubleValue + userCpu.doubleValue + niceCpu.doubleValue;
        NSString *systemCpuStr = [NSString stringWithFormat:@"%.1f",systemCpu];
        __block NSString *appNetReceivedStr = @"0.0";
        //流量
        //    [Store.shared networkByteDidChangeWithChange:^(double byte) {
        //        appNetReceivedStr = [NSString stringWithFormat:@"%.1f",byte/1024];
        //    }];
//        NSString *appNetwork = [weakSelf getStringAppTrafficDataInformation];
//        if (appNetwork) {
//             [self normalDataStrAppendwith:appNetwork];
//        }
        NSString *normS = [weakSelf getStringResourceDataTime:currntime withFPS:fpsStr withAppRam:appRamStr withSysRam:sysRamPercentStr withAppCpu:appCpuStr withSysCpu:systemCpuStr withAppNetReceived:appNetReceivedStr];
        [self normalDataStrAppendwith:normS];
    }] copy];
}
//停止监控基本数据获取
- (void)stopResourceData {
    self.isStartCasch = NO;
    [self clearCache];
    if (td_resource_monitorData_callback_key == nil) { return; }
    [TDGlobalTimer resignTimerCallbackWithKey: td_resource_monitorData_callback_key];
    td_resource_monitorData_callback_key = NULL;
}
//停止写入监控性能数据
- (void)stopUploadResourceData {
    //保证收集上数据都能写入沙盒中
    [self endWriteData];
    self.isStartCasch = NO;
    if (td_resource_monitorData_callback_key == nil) { return; }
    [TDGlobalTimer resignTimerCallbackWithKey: td_resource_monitorData_callback_key];
    td_resource_monitorData_callback_key = NULL;
    if (td_resource_recordDataIntervalTime_callback_key == nil) { return; }
    [TDGlobalTimer uploadResignTimerCallbackWithKey: td_resource_recordDataIntervalTime_callback_key];
     td_resource_recordDataIntervalTime_callback_key = NULL;
}
////拼接开始或结束时间 startEndTime: 开始或结束时间 ,isStartTime是否开始还是结束时间
- (void)getStringResourceDataTime:(NSString *)currntTime withStartOrEndTime:(NSString *)startEndTime withIsStartTime:(BOOL) isStartTime {
    if (isStartTime) {
        //将开始时间拼接在这里
        NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^startResourceDataTime", logNum,currntTime];
        @synchronized (self) {
            [self logNumAddOne];
            [att appendFormat:@"^%@",startEndTime]; //开始时间
            [att appendFormat:@"^%@",@"\n"];
        }
         [self normalDataStrAppendwith:att];
    }else{
        //将结束时间拼接在这里
        NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^stopResourceDataTime", logNum,currntTime];
        @synchronized (self) {
            [self logNumAddOne];
            [att appendFormat:@"^%@",startEndTime]; //开始时间
            [att appendFormat:@"^%@",@"\n"];
        }
         [self normalDataStrAppendwith:att];
    }
}
//异步获取数据,生命周期方法名
- (void)asyncExecuteClassName:(NSString *)className withStartTime:(NSString *)startTime withEndTime:(NSString *)endTime withHookMethod:(NSString *)hookMethod withUniqueIdentifier:(NSString *)uniqueIdentifier {
    if (!self.isStartCasch) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self asyncExecute:^{
       // NSLog(@"className=%@---hookMethod=%@",uniqueIdentifier,hookMethod);
        long long curt = [self currentTime];
        NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
        NSString *hookS = [weakSelf getStringExecuteTime:currntime withClassName:className withStartTime:startTime withEndTime:endTime withHookMethod:hookMethod  withUniqueIdentifier: uniqueIdentifier];
        [weakSelf normalDataStrAppendwith:hookS];
    }];
}
//app基本性能数据
- (NSString *)getStringResourceDataTime:(NSString *)currntTime withFPS:(NSString *)fps withAppRam:(NSString *)appRam withSysRam:(NSString *)sysRam withAppCpu:(NSString *)appCpu withSysCpu:(NSString *)sysCpu
    withAppNetReceived:(NSString *)appNetReceived{
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^normalCollect", logNum,currntTime];
    @synchronized (self) {
        [self logNumAddOne];
        [att appendFormat:@"^%@",appCpu]; //百分比
        [att appendFormat:@"^%@",sysCpu]; //百分比
        [att appendFormat:@"^%@",appRam]; //Byte
        [att appendFormat:@"^%@",sysRam]; //百分比
        long long uploadFlow = [TDNetFlowDataSource shareInstance].uploadFlow;
        long long downFlow = [TDNetFlowDataSource shareInstance].downFlow;
        //清空
      //  [[TDNetFlowDataSource shareInstance] clear];
        
        [att appendFormat:@"^%lld",uploadFlow];//上行流量
        [att appendFormat:@"^%lld",downFlow]; //下行流量
        [att appendFormat:@"^%@",@"\n"];
       
    }
    return att.copy;
    
}
//app基本信息数据
- (NSString *)getStringAppBaseDataTime:(NSString *)currntTime withBundleId:(NSString *)bid
                           withAppName:(NSString *)appName withAppVersion:(NSString *)appVersion
                           withDeviceVersion:(NSString *)deviceVersion withDeviceName:(NSString *)deviceName{
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^appCollect", logNum,currntTime];
    @synchronized (self) {
        [self logNumAddOne];
        [att appendFormat:@"^%@",bid];
        [att appendFormat:@"^%@",appName];
        [att appendFormat:@"^%@",appVersion];
        [att appendFormat:@"^%@",deviceVersion];
        [att appendFormat:@"^%@",deviceName];
        [att appendFormat:@"^100"];
        [att appendFormat:@"^%@",@"\n"];
    }
    return att.copy;
    
}
//app启动时间
- (NSString *)getStringAppStartupTime:(NSTimeInterval)appStartupTime {
    
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^1000^appStartupTime", logNum];
    @synchronized (self) {
        [self logNumAddOne];
        NSString *startupTimeS = [NSString stringWithFormat:@"%f",appStartupTime];
        [att appendFormat:@"^%@",startupTimeS];
        [att appendFormat:@"^%@",@"\n"];
    }
    return att.copy;
}
//页面生命周期方法,uniqueIdentifier:页面唯一标识
- (NSString *)getStringExecuteTime:(NSString *)currntTime withClassName:(NSString *)className withStartTime:(NSString *)startTime withEndTime:(NSString *)endTime withHookMethod:(NSString *)hookMethod withUniqueIdentifier:(NSString *)uniqueIdentifier{
    NSMutableString *hookSt = [[NSMutableString alloc]initWithFormat:@"%ld^%@^%@", logNum,currntTime,hookMethod];
    @synchronized (self) {
        [self logNumAddOne];
        [hookSt appendFormat:@"^%@",className];
        [hookSt appendFormat:@"^%@",uniqueIdentifier];
        [hookSt appendFormat:@"^%@",startTime];
        [hookSt appendFormat:@"^%@",endTime];
        [hookSt appendFormat:@"^%@",@"\n"];
    }
    return hookSt.copy;
}
//页面渲染时间
- (NSString *)getRenderWithClassName:(NSString *)className withRenderTime:(NSString *)renderTime {
    long long curt = [self currentTime];
    NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
    NSMutableString *renderStr = [[NSMutableString alloc]initWithFormat:@"%ld^%@^renderCollect", logNum,currntime];
    @synchronized (self) {
        [self logNumAddOne];
        [renderStr appendFormat:@"^%@",className];
        [renderStr appendFormat:@"^%@",renderTime];
        [renderStr appendFormat:@"^%@",@"\n"];
    }
    return renderStr.copy;
}
//app流量数据
- (NSString *)getStringAppTrafficDataInformation {
    
//    NSArray <TDNetworkTrafficLog *> *httpArray = [TDNetFlowDataSource shareInstance].httpModelArray;
//    if (!httpArray || httpArray.count <= 0 ) {
//        return nil;
//    }
    NSMutableString *att1 = [[NSMutableString alloc]init];
    @synchronized (self) {
//        for (TDNetworkTrafficLog *model in httpArray) {
//            NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^1000^AppTrafficDataInformation", logNum];
//            [self logNumAddOne];
//            [att appendFormat:@"^%ld",(long)model.type]; //上行流量还是下行流量,0表示请求/上行流量,1表示接受/下行流量
//            [att appendFormat:@"^%@",model.host];
//            [att appendFormat:@"^%@",model.path];
//        
//            [att appendFormat:@"^%ld",(long)model.headerLength];
//            [att appendFormat:@"^%ld",(long)model.lineLength];
//            [att appendFormat:@"^%ld",(long)model.bodyLength];
//            [att appendFormat:@"^%ld",(long)model.length];
//    
//            [att appendFormat:@"^%@",model.occurTime];//开始时间
//            [att appendFormat:@"^%@",model.startTime];//开始时间
//            [att appendFormat:@"^%@",model.endTime];//结束时间
//            [att appendFormat:@"^%@",@"\n"];
//            [att1 appendString:att];
//        }
//        //清空数组
//        [[TDNetFlowDataSource shareInstance] clear];
    }
    return att1.copy;
}
- (void)asyncExecute: (dispatch_block_t)block {
    assert(block != nil);
    if ([NSThread isMainThread]) {
        TDDispatchQueueAsyncBlockInUtility(block);
    } else {
        block();
    }
}
- (NSMutableString *)normalDataStr {
    if (_normalDataStr) {
        return _normalDataStr;
    }
    _normalDataStr = [[NSMutableString alloc] init];
    return _normalDataStr;
}
#pragma mark - GodEyeDelegate
//网络流量
//- (void)networkEyeDidCatchWith:(NSURLRequest *)request response:(NSURLResponse *)response data:(NSData *)data
//{
//    if (response != nil) {
//        [Store.shared addNetworkByte:response.expectedContentLength];
//    }
//
//}
//检测到内存泄漏
-(void)leakEye:(LeakEye *)leakEye didCatchLeak:(NSObject *)object
{
    long long curt = [self currentTime];
    NSString *currntTime = [NSString stringWithFormat:@"%lld",curt];
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^leakCollect",logNum,currntTime];
    @synchronized (self) {
        [self logNumAddOne];
        [att appendFormat:@"^%@",NSStringFromClass(object.classForCoder)];
        [att appendFormat:@"^%@",object];
        [att appendFormat:@"^%@",@"\n"];
    }
    [self normalDataStrAppendwith:att];
}

//检测到crash
- (void)crashEyeDidCatchCrashWith:(CrashModel *)model
{
    NSString *str = [self getCrashInfoWithModel:model];
    [self normalDataStrAppendwith:str];
}

//app的crash数据
- (NSString *)getCrashInfoWithModel:(CrashModel *)model {
    
    NSString *type = model.type;
    NSString *name = model.name;
    NSString *reason = model.reason;
    NSString *appinfo = model.appinfo;
    NSString *callStack = model.callStack;
    
    long long curt = [self currentTime];
    NSString *currntTime = [NSString stringWithFormat:@"%lld",curt];
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^CrashCollect", logNum,currntTime];
    @synchronized (self) {
        [self logNumAddOne];
        [att appendFormat:@"^%@",type];
        [att appendFormat:@"^%@",name];
        [att appendFormat:@"^%@",reason];
        [att appendFormat:@"^%@",appinfo];
        [att appendFormat:@"^%@",callStack];
        [att appendFormat:@"^%@",@"\n"];
    }
    return att.copy;
    
}

//检测到卡顿
- (void)anrEyeWithAnrEye:(ANREye *)anrEye catchWithThreshold:(double)threshold mainThreadBacktrace:(NSString *)mainThreadBacktrace allThreadBacktrace:(NSString *)allThreadBacktrace
{
//    //##&&**###INRCollect作为唯一标识
//    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^", logNum,[self getCurrntTime]];
//    @synchronized (self) {
//        [self logNumAddOne];
//        [att appendFormat:@"^%f",threshold];
//        [att appendFormat:@"%@^%@%@",@"\n",@"##&&**###INRCollectAllThreadBacktrace",@"\n"];
//        [att appendFormat:@"%@",mainThreadBacktrace];
//        [att appendFormat:@"%@^%@%@",@"\n",@"##&&**###INRCollectAllThreadBacktrace",@"\n"];
//        [att appendFormat:@"%@",allThreadBacktrace];
//        [att appendFormat:@"^%@",@"\n"];
//    }
//    [self normalDataStrAppendwith:att];
}
- (void)anrEyeWithAnrEye:(ANREye *)anrEye startTime:(int64_t)startTime endTime:(int64_t)endTime catchWithThreshold:(double)threshold mainThreadBacktrace:(NSString *)mainThreadBacktrace allThreadBacktrace:(NSString *)allThreadBacktrace {
    //NSMutableString *mainThradB = [[NSMutableString alloc]init];
    NSString *mainThradB = [mainThreadBacktrace stringByReplacingOccurrencesOfString:@"\n" withString:@"#&####"];
    //##&&**###INRCollect作为唯一标识
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^INRCollectMainThread", (long)logNum,[self getCurrntTime]];
    @synchronized (self) {
        [self logNumAddOne];
     //   long long startTime1 = self ->startTime;
        //开始时间
        [att appendFormat:@"^%lld",startTime];
        //结束时间
        [att appendFormat:@"^%lld",endTime];
        //卡顿时长
        [att appendFormat:@"^%lld",endTime - startTime];
       // [att appendFormat:@"%@^%@%@",@"\n",@"##&&**###INRCollectAllThreadBacktrace",@"\n"];
        [att appendFormat:@"^%@",mainThradB];
      //  [att appendFormat:@"%@^%@%@",@"\n",@"##&&**###INRCollectAllThreadBacktrace",@"\n"];
       // [att appendFormat:@"%@",allThreadBacktrace];
        [att appendFormat:@"^%@",@"\n"];
    }
    [self normalDataStrAppendwith:att];
}
#pragma mark - TDFPSMonitorDelegate
//fpsCount 1秒内或者大于1s(出现卡顿时),帧率次数,catonTime卡顿时长,currntTime当前时间
- (void)fpsMonitor: (NSUInteger)fpsCount withCatonTime: (double)catonTime withCurrentTime:(NSString *)currntTime withStackInformation: (NSString *)stackInformation {
    if (!self.isStartCasch) {
        return;
    }
     NSString *mainThradB = [stackInformation stringByReplacingOccurrencesOfString:@"\n" withString:@"#&####"];
    __weak typeof(self) weakSelf = self;
    [self asyncExecute:^{
        long long curt = [self currentTime];
        NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
        NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^FPSCollect", logNum,currntime];
        @synchronized (self) {
            [self logNumAddOne];
            //fps频率
            [att appendFormat:@"^%@",[NSString stringWithFormat:@"%lu",(unsigned long)fpsCount]];
            //两者频率刷新时间(大于=1s)
            [att appendFormat:@"^%@",[NSString stringWithFormat:@"%f",catonTime]];
            //获取时间
            [att appendFormat:@"^%@",currntTime];
            //堆栈信息
            if (stackInformation != nil) {
                [att appendFormat:@"^%@",mainThradB];
            }else{
                [att appendFormat:@"^  "];
            }
            [att appendFormat:@"^%@",@"\n"];
        }
        [weakSelf normalDataStrAppendwith:att];
    }];
}
//获取帧率时间
- (void)fpsFrameCurrentTime:(NSString *)currentTime {
    
    __weak typeof(self) weakSelf = self;
    [self asyncExecute:^{
        long long curt = [self currentTime];
        NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
        NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^FPSCollect", logNum,currntime];
        @synchronized (self) {
            [self logNumAddOne];
            //获取时间
            [att appendFormat:@"^%@",currentTime];
            [att appendFormat:@"^%@",@"\n"];
        }
        [weakSelf normalDataStrAppendwith:att];
    }];
}
//获取卡顿信息
#pragma mark - TDPerformanceMonitorDelegate
- (void)performanceMonitorCatonInformation:(NSString *)startTime withEndTime:(NSString *)endTime withCatonStackInformation:(NSString *)mainThreadBacktrace {
    
    NSString *mainThradB = [mainThreadBacktrace stringByReplacingOccurrencesOfString:@"\n" withString:@"#&####"];
    //##&&**###INRCollect作为唯一标识
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^PerformanceMonitorINRCollectMainThread", (long)logNum,[self getCurrntTime]];
    @synchronized (self) {
        [self logNumAddOne];
        //   long long startTime1 = self ->startTime;
        //开始时间
        //        [att appendFormat:@"^%lld",startTime];
        //        //结束时间
        //        [att appendFormat:@"^%lld",endTime];
        //        //卡顿时长
        //        [att appendFormat:@"^%lld",endTime - startTime];
        // [att appendFormat:@"%@^%@%@",@"\n",@"##&&**###INRCollectAllThreadBacktrace",@"\n"];
        [att appendFormat:@"^%@",mainThradB];
        //  [att appendFormat:@"%@^%@%@",@"\n",@"##&&**###INRCollectAllThreadBacktrace",@"\n"];
        // [att appendFormat:@"%@",allThreadBacktrace];
        [att appendFormat:@"^%@",@"\n"];
    }
    [self normalDataStrAppendwith:att];
}
- (NSString *)getCurrntTime {
    long long curt = [self currentTime];
    NSString *currntTime = [NSString stringWithFormat:@"%lld",curt];
    return currntTime;
}
//获取当前时间
- (long long)currentTime {
    NSTimeInterval time = [[NSDate date] timeIntervalSince1970] * 1000;
    long long dTime = [[NSNumber numberWithDouble:time] longLongValue]; 
    return dTime;
}

@end
