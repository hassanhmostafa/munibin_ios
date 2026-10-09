//
//  MunibinWidgetBundle.swift
//  MunibinWidget
//
//  Created by Hassan Mostafa on 12.09.26.
//

import WidgetKit
import SwiftUI

@main
struct MunibinWidgetBundle: WidgetBundle {
    var body: some Widget {
        MunibinWidget()
        if #available(iOSApplicationExtension 16.2, *) {
            MunibinPrayerLiveActivity()
        }
    }
}
