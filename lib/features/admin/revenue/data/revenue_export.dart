// Builds the admin revenue export as a real .xlsx workbook (opens in
// Excel / Google Sheets / Numbers). Two styled sheets:
//   • Summary      — every metric × every period, header info on top
//   • Transactions — every platform-revenue row, newest first
//
// Amounts are written as native INTEGER cells with a thousands format
// (#,##0) so they're real, sortable, summable numbers — not text.
// Dates are native DATE-TIME cells. Headers are bold on a brand-brown
// fill. Speaker earnings are deliberately NOT included.

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import 'package:gospel_vox/features/admin/revenue/data/revenue_models.dart';

DateTimeCellValue _dt(DateTime d) => DateTimeCellValue(
      year: d.year,
      month: d.month,
      day: d.day,
      hour: d.hour,
      minute: d.minute,
      second: d.second,
    );

void _put(Sheet sheet, int col, int row, CellValue value, {CellStyle? style}) {
  final cell =
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
  cell.value = value;
  if (style != null) cell.cellStyle = style;
}

List<int> buildRevenueXlsx(RevenueData data, DateTime now) {
  final excel = Excel.createExcel();

  // ── Shared styles ──
  final titleStyle = CellStyle(
    bold: true,
    fontSize: 15,
    fontColorHex: ExcelColor.fromHexString('FF6B3A2A'),
  );
  final labelStyle = CellStyle(bold: true);
  final headerStyle = CellStyle(
    bold: true,
    fontColorHex: ExcelColor.white,
    backgroundColorHex: ExcelColor.fromHexString('FF6B3A2A'),
    horizontalAlign: HorizontalAlign.Center,
    verticalAlign: VerticalAlign.Center,
  );
  final moneyStyle = CellStyle(
    numberFormat: NumFormat.custom(formatCode: '#,##0'),
    horizontalAlign: HorizontalAlign.Right,
  );
  final moneyHeaderRight = CellStyle(
    bold: true,
    fontColorHex: ExcelColor.white,
    backgroundColorHex: ExcelColor.fromHexString('FF6B3A2A'),
    horizontalAlign: HorizontalAlign.Right,
  );
  final dateStyle = CellStyle(
    numberFormat: NumFormat.custom(formatCode: 'yyyy-mm-dd  hh:mm'),
  );

  _buildSummary(
      excel, data, now, titleStyle, labelStyle, headerStyle, moneyStyle,
      moneyHeaderRight, dateStyle);
  _buildTransactions(excel, data, headerStyle, moneyHeaderRight, moneyStyle,
      dateStyle);

  // Drop the auto-created default sheet so the file opens on Summary.
  if (excel.tables.containsKey('Sheet1')) {
    excel.delete('Sheet1');
  }

  final bytes = excel.encode();
  return bytes ?? <int>[];
}

void _buildSummary(
  Excel excel,
  RevenueData data,
  DateTime now,
  CellStyle titleStyle,
  CellStyle labelStyle,
  CellStyle headerStyle,
  CellStyle moneyStyle,
  CellStyle moneyHeaderRight,
  CellStyle dateStyle,
) {
  final s = excel['Summary'];

  _put(s, 0, 0, TextCellValue('Gospel Vox — Revenue Report'),
      style: titleStyle);

  _put(s, 0, 2, TextCellValue('Generated'), style: labelStyle);
  _put(s, 1, 2, _dt(now), style: dateStyle);
  _put(s, 0, 3, TextCellValue('Store fee assumption'), style: labelStyle);
  _put(s, 1, 3, TextCellValue('${data.storeCutPercent}%'));
  _put(s, 0, 4, TextCellValue('Currency'), style: labelStyle);
  _put(s, 1, 4, TextCellValue('INR (₹)'));

  // Table header row.
  const headerRow = 6;
  final periods = RevenuePeriod.values; // today, week, month, all
  _put(s, 0, headerRow, TextCellValue('Metric'), style: headerStyle);
  for (var i = 0; i < periods.length; i++) {
    _put(s, i + 1, headerRow, TextCellValue(periods[i].longLabel),
        style: moneyHeaderRight);
  }

  var r = headerRow + 1;
  void row(String label, double Function(RevenuePeriod p) value) {
    _put(s, 0, r, TextCellValue(label), style: labelStyle);
    for (var i = 0; i < periods.length; i++) {
      _put(s, i + 1, r, IntCellValue(value(periods[i]).round()),
          style: moneyStyle);
    }
    r++;
  }

  row('Total Revenue', (p) => data.totalFor(p, now));
  row('Calls & Chats commission',
      (p) => data.sourceTotal(RevenueSource.callChat, p, now));
  row('Bible Sessions commission',
      (p) => data.sourceTotal(RevenueSource.bible, p, now));
  row('Activation Fees',
      (p) => data.sourceTotal(RevenueSource.activation, p, now));
  row('Gross coin sales (customers paid)',
      (p) => data.grossSalesFor(p, now));
  row('Est. received after ${data.storeCutPercent}% store fee',
      (p) => data.grossSalesFor(p, now) * (1 - data.storeCutPercent / 100));

  s.setColumnWidth(0, 36);
  for (var i = 1; i <= periods.length; i++) {
    s.setColumnWidth(i, 16);
  }
}

void _buildTransactions(
  Excel excel,
  RevenueData data,
  CellStyle headerStyle,
  CellStyle moneyHeaderRight,
  CellStyle moneyStyle,
  CellStyle dateStyle,
) {
  final s = excel['Transactions'];

  _put(s, 0, 0, TextCellValue('Date & Time'), style: headerStyle);
  _put(s, 1, 0, TextCellValue('Source'), style: headerStyle);
  _put(s, 2, 0, TextCellValue('Description'), style: headerStyle);
  _put(s, 3, 0, TextCellValue('Amount (₹)'), style: moneyHeaderRight);

  final txns = [...data.txns]..sort((a, b) {
      final ax = a.at;
      final bx = b.at;
      if (ax == null && bx == null) return 0;
      if (ax == null) return 1;
      if (bx == null) return -1;
      return bx.compareTo(ax);
    });

  var r = 1;
  for (final t in txns) {
    if (t.at != null) {
      _put(s, 0, r, _dt(t.at!), style: dateStyle);
    } else {
      _put(s, 0, r, TextCellValue('—'));
    }
    _put(s, 1, r, TextCellValue(t.source.label));
    _put(s, 2, r, TextCellValue(t.title));
    _put(s, 3, r, IntCellValue(t.amount.round()), style: moneyStyle);
    r++;
  }

  s.setColumnWidth(0, 20);
  s.setColumnWidth(1, 18);
  s.setColumnWidth(2, 34);
  s.setColumnWidth(3, 14);
}

// Suggested file name, e.g. gospelvox_revenue_20260627_1145.xlsx
String revenueXlsxFileName(DateTime now) {
  final stamp = DateFormat('yyyyMMdd_HHmm').format(now);
  return 'gospelvox_revenue_$stamp.xlsx';
}
