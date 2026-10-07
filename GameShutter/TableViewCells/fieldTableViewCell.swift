//
//  fieldTableViewCell.swift
//  GameShutter
//
//  Created by Hanhui Zhang on 6/13/20.
//  Copyright © 2020 Jabson. All rights reserved.
//

import UIKit

class fieldTableViewCell: UITableViewCell, UITextFieldDelegate {
    static let identifier = "fieldTableViewCell"
    static func nib() -> UINib {
        return UINib(nibName: "fieldTableViewCell", bundle: nil)
    }
    
    @IBOutlet var field: UITextField!
    @IBOutlet var label: UILabel!
    
    override func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
        field.placeholder = "Highlight Album Name"
        field.delegate = self
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        print("\(textField.text ?? "")")
        return true
    }
}
