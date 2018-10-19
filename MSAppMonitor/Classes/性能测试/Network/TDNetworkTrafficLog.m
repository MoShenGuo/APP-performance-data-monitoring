//
//  TDNetworkTrafficLog.m
//  AFNetworking
//
//  Created by guoxiaoliang on 2018/10/17.
//

#import "TDNetworkTrafficLog.h"

@implementation TDNetworkTrafficLog
- (void)settingOccurTime {
    self.occurTime = [self getCurrntTime];
}
- (NSString *)getCurrntTime { 
    long long curt = [self currentTime];
    NSString *currntTime = [NSString stringWithFormat:@"%lld",curt];
    return currntTime;
//    NSDateFormatter * formatter = [[NSDateFormatter alloc ] init];  
//    [formatter setDateFormat:@"YYYY-MM-dd hh:mm:ss:SSS"];    
//    NSString *date =  [formatter stringFromDate:[NSDate date]];  
//    NSString *timeLocal = [[NSString alloc] initWithFormat:@"%@", date]; 
//    return timeLocal;
}
//获取当前时间
- (long long)currentTime {
    NSTimeInterval time = [[NSDate date] timeIntervalSince1970] * 1000;
    long long dTime = [[NSNumber numberWithDouble:time] longLongValue]; 
    return dTime;
}
@end
