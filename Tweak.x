#import <UIKit/UIKit.h>
#import "src/APS.h"

%ctor {
    [[APSPlugin shared] start];
}
