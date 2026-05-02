import SwiftUI
import SwiftData

struct CalendarView: View {
    @Query(sort: \RideSessionModel.date, order: .reverse) private var sessions: [RideSessionModel]
    @State private var displayedMonth: Date = Date()
    @State private var selectedDay: Int?

    private let calendar = Calendar(identifier: .iso8601)
    private let dayHeaders = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Cells in the LazyVGrid month layout. Wrapped in an Identifiable enum
    /// so the leading-empty cells and day cells don't share integer IDs
    /// when both sit in the same grid — SwiftUI dedupes by id and drops the
    /// later items, which hid days 1-3 of any month starting after Monday.
    private enum MonthCell: Identifiable {
        case empty(Int)
        case day(Int)
        var id: String {
            switch self {
            case .empty(let i): return "empty-\(i)"
            case .day(let d): return "day-\(d)"
            }
        }
    }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth))!
    }

    private var daysInMonth: Int {
        calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30
    }

    private var leadingEmptyCells: Int {
        let weekday = calendar.component(.weekday, from: monthStart) // Sun=1 ... Sat=7 in gregorian; ISO Mon=2..
        // For ISO calendar Mon=1..Sun=7, but Apple's gregorian is Sun=1. Using gregorian via .weekday gives Sun=1.
        // We want Mon-based offset 0..6 for Mon..Sun.
        let g = Calendar(identifier: .gregorian)
        let w = g.component(.weekday, from: monthStart) - 1 // Sun=0..Sat=6
        return (w + 6) % 7 // Mon=0..Sun=6
    }

    private var monthlyRides: [Int: [RideSessionModel]] {
        var bucket: [Int: [RideSessionModel]] = [:]
        let g = Calendar(identifier: .gregorian)
        let m = g.component(.month, from: displayedMonth)
        let y = g.component(.year, from: displayedMonth)
        for s in sessions {
            let mm = g.component(.month, from: s.date)
            let yy = g.component(.year, from: s.date)
            if mm == m && yy == y {
                let day = g.component(.day, from: s.date)
                bucket[day, default: []].append(s)
            }
        }
        return bucket
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                monthNav
                    .padding(.horizontal, CJSpacing.l)
                    .padding(.vertical, CJSpacing.m)

                grid
                    .padding(.horizontal, CJSpacing.l)

                Divider().background(CJColors.border).padding(.vertical, CJSpacing.m)

                if let day = selectedDay {
                    dayDetail(day: day, rides: monthlyRides[day] ?? [])
                        .padding(.horizontal, CJSpacing.l)
                }

                Spacer()
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("Calendar")
            .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var monthNav: some View {
        HStack {
            Button {
                shift(by: -1)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
            }
            .frame(width: 36, height: 36)
            .background(CJColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Spacer()
            Text(monthLabel).font(CJFont.title).foregroundStyle(CJColors.textPrimary)
            Spacer()

            Button {
                shift(by: 1)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold))
            }
            .frame(width: 36, height: 36)
            .background(CJColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .tint(CJColors.textPrimary)
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: displayedMonth)
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        let g = Calendar(identifier: .gregorian)
        let todayDay = g.isDate(Date(), equalTo: displayedMonth, toGranularity: .month)
            ? g.component(.day, from: Date()) : nil

        var cells: [MonthCell] = []
        for i in 0..<leadingEmptyCells { cells.append(.empty(i)) }
        for d in 1...daysInMonth { cells.append(.day(d)) }

        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(dayHeaders, id: \.self) { h in
                Text(h)
                    .font(CJFont.small)
                    .foregroundStyle(CJColors.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            ForEach(cells) { cell in
                switch cell {
                case .empty:
                    Rectangle().fill(.clear).frame(height: 44)
                case .day(let d):
                    dayCell(day: d, isToday: d == todayDay)
                }
            }
        }
    }

    private func dayCell(day: Int, isToday: Bool) -> some View {
        let rides = monthlyRides[day] ?? []
        let hasRides = !rides.isEmpty
        let isSelected = selectedDay == day

        return Button {
            selectedDay = (selectedDay == day) ? nil : day
        } label: {
            VStack(spacing: 2) {
                Text("\(day)")
                    .font(CJFont.body)
                    .foregroundStyle(isToday ? CJColors.accent : CJColors.textPrimary)
                if hasRides {
                    Circle()
                        .fill(CJColors.accent)
                        .frame(width: 6, height: 6)
                        .overlay(alignment: .topTrailing) {
                            if rides.count > 1 {
                                Text("\(rides.count)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(CJColors.bgPrimary)
                                    .padding(.horizontal, 3)
                                    .background(CJColors.accent)
                                    .clipShape(Capsule())
                                    .offset(x: 8, y: -6)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? CJColors.accent.opacity(0.18) : CJColors.card.opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isToday ? CJColors.accent : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func dayDetail(day: Int, rides: [RideSessionModel]) -> some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text(headerForDay(day))
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)
            if rides.isEmpty {
                Text("No rides on this day")
                    .font(CJFont.body)
                    .foregroundStyle(CJColors.textMuted)
            } else {
                ForEach(rides) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.workoutName)
                                .font(CJFont.body)
                                .foregroundStyle(CJColors.textPrimary)
                            Text(timeFor(r.date))
                                .font(CJFont.caption)
                                .foregroundStyle(CJColors.textMuted)
                        }
                        Spacer()
                        Text(TimeFormat.duration(r.durationSec))
                            .font(CJFont.caption)
                            .foregroundStyle(CJColors.textSecondary)
                            .monospacedDigit()
                        Text("TSS \(r.tss)")
                            .font(CJFont.caption)
                            .foregroundStyle(CJColors.accent)
                            .monospacedDigit()
                    }
                    .padding(CJSpacing.s)
                    .background(CJColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: CJRadius.small))
                }
            }
        }
    }

    private func headerForDay(_ day: Int) -> String {
        let g = Calendar(identifier: .gregorian)
        var c = g.dateComponents([.year, .month], from: displayedMonth)
        c.day = day
        let date = g.date(from: c) ?? displayedMonth
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return f.string(from: date)
    }

    private func timeFor(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func shift(by months: Int) {
        let g = Calendar(identifier: .gregorian)
        if let newDate = g.date(byAdding: .month, value: months, to: displayedMonth) {
            displayedMonth = newDate
            selectedDay = nil
        }
    }
}
