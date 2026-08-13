class HolidayCalendar {
  HolidayCalendar(this.entries);

  final Map<String, bool> entries;

  DayType dayType(DateTime date) {
    final key = date.toIso8601String().substring(0, 10);
    final official = entries[key];
    if (official == false) return DayType.workday;
    if (official == true) return DayType.statutoryHoliday;
    if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
      return DayType.weekend;
    }
    return DayType.workday;
  }

  bool isDayOff(DateTime date) => dayType(date) != DayType.workday;

  static final defaults2026 = <String, bool>{
    for (final day in <String>[
      '2026-01-01',
      '2026-01-02',
      '2026-01-03',
      '2026-02-15',
      '2026-02-16',
      '2026-02-17',
      '2026-02-18',
      '2026-02-19',
      '2026-02-20',
      '2026-02-21',
      '2026-02-22',
      '2026-02-23',
      '2026-04-04',
      '2026-04-05',
      '2026-04-06',
      '2026-05-01',
      '2026-05-02',
      '2026-05-03',
      '2026-05-04',
      '2026-05-05',
      '2026-06-19',
      '2026-06-20',
      '2026-06-21',
      '2026-09-25',
      '2026-09-26',
      '2026-09-27',
      '2026-10-01',
      '2026-10-02',
      '2026-10-03',
      '2026-10-04',
      '2026-10-05',
      '2026-10-06',
      '2026-10-07',
    ])
      day: true,
    for (final day in <String>[
      '2026-01-04',
      '2026-02-14',
      '2026-02-28',
      '2026-05-09',
      '2026-09-20',
      '2026-10-10',
    ])
      day: false,
  };
}

enum DayType { workday, statutoryHoliday, weekend }

extension DayTypeLabel on DayType {
  String get label => switch (this) {
    DayType.workday => '工作日',
    DayType.statutoryHoliday => '法定节假日',
    DayType.weekend => '普通休息日',
  };
}
