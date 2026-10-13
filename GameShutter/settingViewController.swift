//
//  settingViewController.swift
//  GameShutter
//
//  Created by Jason Zhang on 6/12/20.
//

import Foundation
import UIKit

// Which optional zoom presets the camera screen shows. 1× is always shown;
// the others are on until turned off in Settings. Stored in UserDefaults.
enum ZoomPresetSettings {
    static let optionalPresets: [CGFloat] = [0.75, 1.25, 1.5]

    private static func key(for preset: CGFloat) -> String {
        return "zoomPresetEnabled_\(preset)"
    }

    static func isEnabled(_ preset: CGFloat) -> Bool {
        guard optionalPresets.contains(preset) else { return true }
        return UserDefaults.standard.object(forKey: key(for: preset)) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, for preset: CGFloat) {
        UserDefaults.standard.set(enabled, forKey: key(for: preset))
    }
}

class settingViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    private enum Section: Int, CaseIterable {
        case highlight, zoomPresets
    }

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
        return Section.allCases.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let label = UILabel()
        label.text = Section(rawValue: section) == .zoomPresets ? "Zoom Presets" : "Highlight"
        label.backgroundColor = UIColor.lightGray
        return label
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return Section(rawValue: section) == .zoomPresets ? ZoomPresetSettings.optionalPresets.count : 1
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44.0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if Section(rawValue: indexPath.section) == .zoomPresets {
            return zoomPresetCell(for: indexPath.row)
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: optionLabelTableViewCell.identifier, for: indexPath) as! optionLabelTableViewCell
        cell.configure(with: "Highlight Duration", optionValue: "10")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // One switch per optional preset; the camera screen re-reads these when it
    // reappears.
    private func zoomPresetCell(for row: Int) -> UITableViewCell {
        let preset = ZoomPresetSettings.optionalPresets[row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = "Show \(Self.presetName(preset)) button"
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = ZoomPresetSettings.isEnabled(preset)
        toggle.tag = row
        toggle.addTarget(self, action: #selector(zoomPresetToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    @objc private func zoomPresetToggled(_ toggle: UISwitch) {
        ZoomPresetSettings.setEnabled(toggle.isOn, for: ZoomPresetSettings.optionalPresets[toggle.tag])
    }

    private static func presetName(_ preset: CGFloat) -> String {
        let formatter = NumberFormatter()
        formatter.minimumIntegerDigits = 1
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: Double(preset))) ?? "\(preset)") + "×"
    }
}
