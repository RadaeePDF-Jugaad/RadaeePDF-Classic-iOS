//
//  UILShadowView.m
//  PDFViewer
//
//  Created by Emanuele Bortolami on 09/07/2020.
//

#import "UILShadowView.h"
#import "RDUtils.h"
#import "UIView+RDGlass.h"
#import <QuartzCore/QuartzCore.h>

@implementation UILShadowView

/*
// Only override drawRect: if you perform custom drawing.
// An empty implementation adversely affects performance during animation.
- (void)drawRect:(CGRect)rect {
    // Drawing code
}
*/

-(id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if(self)
    {
        [self initLayout];
    }
    return self;
}
-(id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if(self)
    {
        [self initLayout];
    }
    return self;
}

- (void)initLayout {
    self.layer.cornerRadius = 14.0f;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 0.0f);
    self.layer.shadowRadius = 10.0f;
    self.layer.shadowOpacity = 0.25f;
    self.layer.masksToBounds = NO;

    [self rd_applyGlassBackgroundWithCornerRadius:14.0f];
}

@end
