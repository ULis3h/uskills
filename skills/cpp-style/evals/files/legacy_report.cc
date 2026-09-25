#include <string>
#include <vector>
#include <map>
#include <sstream>
#include <iostream>

using namespace std;

struct Sale {
  string region;
  string product;
  double amount;
  int quantity;
};

// Builds a report of total sales per region. If detailed is true, also lists
// each product under the region with its quantity. Returns 0 on success, -1
// if sales is empty, -2 if any amount is negative. The report text is written
// into *out. If top_n > 0 only the top_n regions by amount are included.
int BuildReport(vector<Sale>* sales, bool detailed, int top_n, string* out,
                map<string, double>** totals_out) {
  if (sales->size() == 0) return -1;
  map<string, double>* totals = new map<string, double>();
  map<string, map<string, int> > products;
  for (int i = 0; i < (int)sales->size(); i++) {
    Sale s = (*sales)[i];
    if (s.amount < 0) {
      delete totals;
      return -2;
    }
    (*totals)[s.region] = (*totals)[s.region] + s.amount;
    if (detailed) {
      products[s.region][s.product] = products[s.region][s.product] + s.quantity;
    }
  }
  vector<pair<string, double> > sorted;
  for (map<string, double>::iterator it = totals->begin(); it != totals->end(); ++it) {
    sorted.push_back(make_pair(it->first, it->second));
  }
  for (int i = 0; i < (int)sorted.size(); i++) {
    for (int j = i + 1; j < (int)sorted.size(); j++) {
      if (sorted[j].second > sorted[i].second) {
        pair<string, double> tmp = sorted[i];
        sorted[i] = sorted[j];
        sorted[j] = tmp;
      }
    }
  }
  string result = "";
  int count = 0;
  for (int i = 0; i < (int)sorted.size(); i++) {
    if (top_n > 0 && count >= top_n) break;
    stringstream ss;
    ss << sorted[i].second;
    result = result + sorted[i].first + ": " + ss.str() + "\n";
    if (detailed) {
      map<string, int> p = products[sorted[i].first];
      for (map<string, int>::iterator it = p.begin(); it != p.end(); ++it) {
        stringstream qs;
        qs << it->second;
        result = result + "  " + it->first + " x" + qs.str() + "\n";
      }
    }
    count++;
  }
  *out = result;
  if (totals_out != NULL) {
    *totals_out = totals;
  } else {
    delete totals;
  }
  return 0;
}
