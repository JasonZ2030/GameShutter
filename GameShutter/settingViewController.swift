//
//  settingViewController.swift
//  GameShutter
//
//  Created by Jason Zhang on 6/12/20.
//

import Foundation
import UIKit

class settingViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    @IBOutlet var table: UITableView!

    override func viewDidLoad() {
        super.viewDidLoad()
        self.navigationController?.setNavigationBarHidden(false, animated: false)
        self.navigationItem.title = "Settings"

        table.register(optionLabelTableViewCell.nib(), forCellReuseIdentifier: optionLabelTableViewCell.identifier)
        table.delegate = self
        table.dataSource = self
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let label = UILabel()
        label.text = "Highlight"
        label.backgroundColor = UIColor.lightGray
        return label
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44.0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: optionLabelTableViewCell.identifier, for: indexPath) as! optionLabelTableViewCell
        cell.configure(with: "Highlight Duration", optionValue: "10")
        cell.accessoryType = .disclosureIndicator
        return cell
    }
}
