/// A group template as offered on the onboarding screen.
class GroupTemplate {
  const GroupTemplate(this.name, this.costCategories);

  final String name;

  /// The cost chips the template fills in for each session.
  final List<String> costCategories;
}

/// Mirrors `Petepete.Groups.Templates` in the API, which stays the source of truth:
/// the group the API creates answers with its own `cost_categories`. The app lists the
/// defaults up front so the host sees what each template brings before picking one.
const groupTemplates = <GroupTemplate>[
  GroupTemplate('Futsal', [
    'Sewa lapangan',
    'Air minum',
    'Bola',
    'Wasit',
    'Parkir',
  ]),
  GroupTemplate('Badminton', [
    'Sewa lapangan',
    'Shuttlecock',
    'Air minum',
    'Parkir',
  ]),
  GroupTemplate('Padel', ['Sewa lapangan', 'Bola', 'Air minum', 'Parkir']),
  GroupTemplate('Mini Soccer', [
    'Sewa lapangan',
    'Wasit',
    'Rompi',
    'Air minum',
    'Parkir',
  ]),
  GroupTemplate('Acara Umum', [
    'Sewa tempat',
    'Konsumsi',
    'Perlengkapan',
    'Lainnya',
  ]),
];

/// New groups round shares up to the nearest Rp1.000 until the host changes it.
const defaultRoundingUnit = 1000;
