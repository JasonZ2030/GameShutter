//
//  optionLabelTableViewCell.swift
//  GameShutter
//
//  Created by Hanhui Zhang on 6/13/20.
//  Copyright © 2020 Jabson. All rights reserved.
//

import UIKit

class optionLabelTableViewCell: UITableViewCell {
    static let identifier = "optionLabelTableViewCell"
    static func nib() -> UINib {
        return UINib(nibName: "optionLabelTableViewCell", bundle: nil)
    }
    public func configure(with optionName: String, optionValue: String){
        OptionName.text = optionName
        OptionValue.text = optionValue
    }
    @IBOutlet var OptionName: UILabel!
    @IBOutlet var OptionValue: UILabel!
    
    override func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }
    
}
